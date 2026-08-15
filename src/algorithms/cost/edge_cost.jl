"""
$TYPEDSIGNATURES

For `NetworkArc` edges the selector is irrelevant (one mode) and the method just forwards to
`incremental_cost!`. The non-buffer methods allocate a fresh `BinPackingBuffer` so ad-hoc
callers (local search, two-node consolidation, tests) stay unchanged.
"""
function _edge_incremental_cost(
    arc::NetworkArc,
    existing,
    new_comms::Vector{C},
    sel::AbstractModeSelector;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    return _edge_incremental_cost(
        BinPackingBuffer(), arc, existing, new_comms, sel; packing=packing
    )
end

function _edge_incremental_cost(
    arc::MultiModalArc,
    existing,
    new_comms::Vector{C},
    sel::AbstractModeSelector;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    return _edge_incremental_cost(
        BinPackingBuffer(), arc, existing, new_comms, sel; packing=packing
    )
end

"""
$TYPEDSIGNATURES

For `NetworkArc` edges the selector is irrelevant (one mode) and the method just forwards to
`incremental_cost!`, threading `buffer`.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::NetworkArc,
    ::Nothing,
    new_comms::Vector{C},
    ::AbstractModeSelector;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    # No existing commodities: both modes pack `new` from scratch and agree.
    return incremental_cost!(buffer, arc.cost, C[], new_comms)
end

"""
$TYPEDSIGNATURES

For `NetworkArc` edges the selector is irrelevant (one mode) and the method just forwards to
`incremental_cost!`, threading `buffer`. Under `packing == :frozen` the
bin-packing increment is computed against the assignment's cached frozen bins
(`existing.bins`) instead of re-packing the commodity union.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    if packing === :frozen
        return _frozen_edge_incremental_cost(buffer, arc.cost, existing, new_comms)
    end
    return incremental_cost!(
        buffer, arc.cost, existing.commodities, new_comms; n_existing=length(existing.bins)
    )
end

"""
$TYPEDSIGNATURES

Frozen-bin per-edge increment for a single-mode assignment. Dispatches on the
arc cost type so only `BinPackingArcCost` and `SumArcCost` use the frozen bin
count; every other cost is linear in volume and identical in both modes, so it
falls back to the standard `incremental_cost!`.
"""
function _frozen_edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
) where {C<:LightCommodity}
    return frozen_incremental_cost!(buffer, arc_f, existing.bins, new_comms)
end

function _frozen_edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc_f::SumArcCost,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
) where {C<:LightCommodity}
    return frozen_incremental_cost!(
        buffer, arc_f, existing.bins, existing.commodities, new_comms
    )
end

function _frozen_edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
) where {C<:LightCommodity}
    # Linear and node-style costs are identical under both packing modes.
    return incremental_cost!(
        buffer, arc_f, existing.commodities, new_comms; n_existing=length(existing.bins)
    )
end

"""
$TYPEDSIGNATURES

For `MultiModalArc` edges and cheapest mode selector, compute the incremental cost of adding
to the cheapest feasible mode (or `Inf` if no single mode can accommodate the new commodities).
Threads `buffer` into each candidate mode's `incremental_cost!`.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    ::Nothing,
    new_comms::Vector{C},
    ::CheapestMode;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    # No existing load: both modes pack `new` from scratch and agree.
    return minimum(
        if _mode_has_capacity(mode, C[], new_comms)
            incremental_cost!(buffer, mode.cost, C[], new_comms)
        else
            Inf
        end for mode in arc.modes
    )
end

"""
$TYPEDSIGNATURES

For `MultiModalArc` edges and cheapest mode selector, compute the incremental cost of adding
to the cheapest feasible mode (or `Inf` if no single mode can accommodate the new commodities).
Threads `buffer` into each candidate mode's `incremental_cost!`.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    existing::MultiAssignment{C},
    new_comms::Vector{C},
    ::CheapestMode;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(arc.modes[i], existing.per_mode[i].commodities, new_comms)
            if packing === :frozen
                _frozen_edge_incremental_cost(
                    buffer, arc.modes[i].cost, existing.per_mode[i], new_comms
                )
            else
                incremental_cost!(
                    buffer,
                    arc.modes[i].cost,
                    existing.per_mode[i].commodities,
                    new_comms;
                    n_existing=length(existing.per_mode[i].bins),
                )
            end
        else
            Inf
        end for i in eachindex(arc.modes)
    )
end

"""
$TYPEDSIGNATURES

For `MultiModalArc` edges and fill-then-spill mode selector, we allow splitting over multiple modes
if the cheapest is full. The incremental cost is the sum of the increments on each mode. Threads
`buffer` into each mode's `incremental_cost!`.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    ::Nothing,
    new_comms::Vector{C},
    ::FillThenSpillMode;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    # FillThenSpillMode always uses ffd_union semantics (its commit re-packs too).
    empty_existing = [C[] for _ in eachindex(arc.modes)]
    partition, overflow = _fill_then_spill_partition(arc, empty_existing, new_comms)
    overflow && return Inf
    total = 0.0
    for i in eachindex(arc.modes)
        isempty(partition[i]) && continue
        total += incremental_cost!(
            buffer, arc.modes[i].cost, empty_existing[i], partition[i]
        )
    end
    return total
end

"""
$TYPEDSIGNATURES
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    existing::MultiAssignment{C},
    new_comms::Vector{C},
    ::FillThenSpillMode;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    # FillThenSpillMode always uses ffd_union semantics (its commit re-packs too).
    existing_per_mode = [slot.commodities for slot in existing.per_mode]
    partition, overflow = _fill_then_spill_partition(arc, existing_per_mode, new_comms)
    overflow && return Inf
    total = 0.0
    for i in eachindex(arc.modes)
        isempty(partition[i]) && continue
        total += incremental_cost!(
            buffer,
            arc.modes[i].cost,
            existing_per_mode[i],
            partition[i];
            n_existing=length(existing.per_mode[i].bins),
        )
    end
    return total
end

function _edge_lower_bound_cost(
    arc::NetworkArc, ::Nothing, new_comms::Vector{C}, ::AbstractModeSelector
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(arc.cost, C[], new_comms)
end

function _edge_lower_bound_cost(
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector,
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(arc.cost, existing.commodities, new_comms)
end

function _edge_lower_bound_cost(
    arc::MultiModalArc, ::Nothing, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        lower_bound_incremental_cost(mode.cost, C[], new_comms) for mode in arc.modes
    )
end

function _edge_lower_bound_cost(
    arc::MultiModalArc, existing::MultiAssignment{C}, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        lower_bound_incremental_cost(
            arc.modes[i].cost, existing.per_mode[i].commodities, new_comms
        ) for i in eachindex(arc.modes)
    )
end
