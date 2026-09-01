# --- Shared frozen-bin helper ------------------------------------------------

"""
$TYPEDSIGNATURES

Frozen-bin per-edge increment for a single-mode assignment. When bins are clean,
dispatches to `frozen_incremental_cost!` (bin-packing terms reuse committed bins,
others fall back to `incremental_cost_with_size` or `incremental_cost!`).
When bins are dirty, falls back to the standard `incremental_cost!`.

Shared by both the `NetworkArc` and per-mode `MultiModalArc` frozen paths (and
reused by `assignment_operations.jl`).
"""
function _frozen_edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    if existing.bins_dirty
        return incremental_cost!(buffer, arc_f, existing.commodities, new_comms)
    end
    # else
    return frozen_incremental_cost!(
        buffer, arc_f, existing.bins, existing.commodities, new_comms, new_total_size
    )
end

# --- Incremental cost: NetworkArc (single mode) ------------------------------
# The selector is irrelevant (one mode); the batch always forwards to the arc's
# own `incremental_cost!`.

"""
$TYPEDSIGNATURES

Empty `NetworkArc`: with no existing commodities, `:frozen` and `:ffd_union`
agree, so the batch is packed from scratch.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::NetworkArc,
    ::Nothing,
    new_comms::Vector{C},
    ::AbstractModeSelector;
    packing::Symbol=:frozen,
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    return incremental_cost!(buffer, arc.cost, nothing, new_comms)
end

"""
$TYPEDSIGNATURES

Loaded `NetworkArc`. Under `packing == :frozen` the bin-packing increment is
computed against the assignment's cached frozen bins (`existing.bins`) via
`_frozen_edge_incremental_cost`; under `:ffd_union` it repacks the existing+new
commodity union.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector;
    packing::Symbol=:frozen,
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    if packing === :frozen
        return _frozen_edge_incremental_cost(
            buffer, arc.cost, existing, new_comms, new_total_size
        )
    end
    n_ex = existing.bins_dirty ? -1 : length(existing.bins)
    return incremental_cost!(
        buffer, arc.cost, existing.commodities, new_comms; n_existing=n_ex
    )
end

# --- Incremental cost: MultiModalArc + CheapestMode --------------------------
# Add the whole batch to the single cheapest feasible mode, or `Inf` if no one
# mode has room. `buffer` is threaded into each candidate mode's cost call.

"""
$TYPEDSIGNATURES

Empty `MultiModalArc` under `CheapestMode`: no existing load, so each mode packs
the batch from scratch and the result is the minimum over feasible modes.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    ::Nothing,
    new_comms::Vector{C},
    ::CheapestMode;
    packing::Symbol=:frozen,
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(mode, 0.0, new_comms)
            incremental_cost!(buffer, mode.cost, nothing, new_comms)
        else
            Inf
        end for mode in arc.modes
    )
end

"""
$TYPEDSIGNATURES

Loaded `MultiModalArc` under `CheapestMode`: minimum over feasible modes of each
mode's increment, computed against that mode's existing slot. Honours `packing`
per mode (`:frozen` reuses the slot's committed bins, `:ffd_union` repacks).
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    existing::MultiAssignment{C},
    new_comms::Vector{C},
    ::CheapestMode;
    packing::Symbol=:frozen,
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(arc.modes[i], existing.per_mode[i].total_size, new_comms)
            if packing === :frozen
                _frozen_edge_incremental_cost(
                    buffer,
                    arc.modes[i].cost,
                    existing.per_mode[i],
                    new_comms,
                    new_total_size,
                )
            else
                n_ex = if existing.per_mode[i].bins_dirty
                    -1
                else
                    length(existing.per_mode[i].bins)
                end
                incremental_cost!(
                    buffer,
                    arc.modes[i].cost,
                    existing.per_mode[i].commodities,
                    new_comms;
                    n_existing=n_ex,
                )
            end
        else
            Inf
        end for i in eachindex(arc.modes)
    )
end

# --- Incremental cost: MultiModalArc + FillThenSpillMode ---------------------
# Allow splitting the batch across modes when the cheapest is full; the cost is
# the sum of the per-mode increments. Always uses ffd_union semantics (the commit
# re-packs too), so `packing` is not consulted here. Returns `Inf` if the batch
# overflows the combined mode capacity.

"""
$TYPEDSIGNATURES

Empty `MultiModalArc` under `FillThenSpillMode`: partition the batch across the
(empty) modes and sum each non-empty part's from-scratch increment.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    ::Nothing,
    new_comms::Vector{C},
    ::FillThenSpillMode;
    packing::Symbol=:frozen,
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
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

Loaded `MultiModalArc` under `FillThenSpillMode`: partition the batch across the
modes' remaining capacity and sum each non-empty part's increment against that
mode's existing commodities.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    existing::MultiAssignment{C},
    new_comms::Vector{C},
    ::FillThenSpillMode;
    packing::Symbol=:frozen,
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    existing_per_mode = [slot.commodities for slot in existing.per_mode]
    cached_sizes = [slot.total_size for slot in existing.per_mode]
    partition, overflow = _fill_then_spill_partition(
        arc, existing_per_mode, new_comms; existing_total_sizes=cached_sizes
    )
    overflow && return Inf
    total = 0.0
    for i in eachindex(arc.modes)
        isempty(partition[i]) && continue
        n_ex = existing.per_mode[i].bins_dirty ? -1 : length(existing.per_mode[i].bins)
        total += incremental_cost!(
            buffer, arc.modes[i].cost, existing_per_mode[i], partition[i]; n_existing=n_ex
        )
    end
    return total
end

# --- Convenience overloads (allocate a scratch buffer) -----------------------
# Entry points for callers that do not maintain a reusable `BinPackingBuffer`.
# They allocate a fresh one and forward to the buffer-threading methods above.

"""
$TYPEDSIGNATURES

Buffer-free `NetworkArc` overload: allocates a scratch `BinPackingBuffer` and
forwards to the buffer-threading method.
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

"""
$TYPEDSIGNATURES

Buffer-free `MultiModalArc` overload: allocates a scratch `BinPackingBuffer` and
forwards to the buffer-threading method.
"""
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

# ============================================================================
# Relaxed lower-bound cost
#
# The optimistic counterpart of `_edge_incremental_cost`: each mode's increment
# comes from `lower_bound_incremental_cost` (fractional bin counts, no capacity
# ceiling), so there is no `:frozen`/`:ffd_union` split and no feasibility gate.
# `NetworkArc` forwards to its single mode; `MultiModalArc` + `CheapestMode`
# takes the minimum over modes. Used by the lower-bound and filtering strategies.
# ============================================================================

"""
$TYPEDSIGNATURES

Empty `NetworkArc` lower bound: relaxed increment of the batch against no load.
"""
function _edge_lower_bound_cost(
    arc::NetworkArc, ::Nothing, new_comms::Vector{C}, ::AbstractModeSelector
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(arc.cost, C[], new_comms)
end

"""
$TYPEDSIGNATURES

Loaded `NetworkArc` lower bound: relaxed increment against the existing
commodities.
"""
function _edge_lower_bound_cost(
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector,
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(arc.cost, existing.commodities, new_comms)
end

"""
$TYPEDSIGNATURES

Empty `MultiModalArc` lower bound under `CheapestMode`: minimum relaxed
increment over modes, each against no load.
"""
function _edge_lower_bound_cost(
    arc::MultiModalArc, ::Nothing, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        lower_bound_incremental_cost(mode.cost, C[], new_comms) for mode in arc.modes
    )
end

"""
$TYPEDSIGNATURES

Loaded `MultiModalArc` lower bound under `CheapestMode`: minimum relaxed
increment over modes, each against that mode's existing commodities.
"""
function _edge_lower_bound_cost(
    arc::MultiModalArc, existing::MultiAssignment{C}, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        lower_bound_incremental_cost(
            arc.modes[i].cost, existing.per_mode[i].commodities, new_comms
        ) for i in eachindex(arc.modes)
    )
end
