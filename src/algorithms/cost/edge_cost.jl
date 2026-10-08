# --- Shared frozen-bin helper ------------------------------------------------

"""
$TYPEDSIGNATURES

Frozen-bin per-edge increment for a single-mode assignment. Dispatches to
`frozen_incremental_cost!` (bin-packing terms reuse committed bins, others fall back to
`incremental_cost_with_size` or `incremental_cost!`).

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
    return frozen_incremental_cost!(
        buffer, arc_f, existing.bins, existing.commodities, new_comms, new_total_size
    )
end

# --- Incremental cost: NetworkArc (single mode) ------------------------------
# The selector is irrelevant (one mode). The empty case packs the batch from
# scratch and the loaded case forwards to `frozen_incremental_cost!`.

"""
$TYPEDSIGNATURES

Empty `NetworkArc`: with no existing commodities the batch is packed from scratch.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::NetworkArc,
    ::Nothing,
    new_comms::Vector{C},
    ::AbstractModeSelector;
    new_total_size::Float64=NaN,
    empty_counts::Union{Nothing,EmptyPackCounts}=nothing,
) where {C<:LightCommodity}
    _mode_has_capacity(arc, 0.0, new_comms) || return Inf
    return empty_incremental_cost!(buffer, arc.cost, new_comms, empty_counts)
end

"""
$TYPEDSIGNATURES

Loaded `NetworkArc`: the bin-packing increment is computed against the assignment's
cached frozen bins (`existing.bins`) via `_frozen_edge_incremental_cost`.
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector;
    new_total_size::Float64=NaN,
    empty_counts::Union{Nothing,EmptyPackCounts}=nothing,
) where {C<:LightCommodity}
    _mode_has_capacity(arc, existing.total_size, new_comms) || return Inf
    return _frozen_edge_incremental_cost(
        buffer, arc.cost, existing, new_comms, new_total_size
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
    new_total_size::Float64=NaN,
    empty_counts::Union{Nothing,EmptyPackCounts}=nothing,
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(mode, 0.0, new_comms)
            empty_incremental_cost!(buffer, mode.cost, new_comms, empty_counts)
        else
            Inf
        end for mode in arc.modes
    )
end

"""
$TYPEDSIGNATURES

Loaded `MultiModalArc` under `CheapestMode`: minimum over feasible modes of each
mode's increment, computed against that mode's existing slot (its committed bins are
reused).
"""
function _edge_incremental_cost(
    buffer::BinPackingBuffer,
    arc::MultiModalArc,
    existing::MultiAssignment{C},
    new_comms::Vector{C},
    ::CheapestMode;
    new_total_size::Float64=NaN,
    empty_counts::Union{Nothing,EmptyPackCounts}=nothing,
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(arc.modes[i], existing.per_mode[i].total_size, new_comms)
            _frozen_edge_incremental_cost(
                buffer, arc.modes[i].cost, existing.per_mode[i], new_comms, new_total_size
            )
        else
            Inf
        end for i in eachindex(arc.modes)
    )
end

# --- Incremental cost: MultiModalArc + FillThenSpillMode ---------------------
# Allow splitting the batch across modes when the cheapest is full. The cost is
# the sum of the per-mode increments. It always uses union semantics (the commit
# repacks too) and returns `Inf` if the batch overflows the combined mode
# capacity.

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
    new_total_size::Float64=NaN,
    empty_counts::Union{Nothing,EmptyPackCounts}=nothing,
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
    new_total_size::Float64=NaN,
    empty_counts::Union{Nothing,EmptyPackCounts}=nothing,
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

# --- Convenience overloads (allocate a scratch buffer) -----------------------
# Entry points for callers that do not maintain a reusable `BinPackingBuffer`.
# They allocate a fresh one and forward to the buffer-threading methods above.

"""
$TYPEDSIGNATURES

Buffer-free `NetworkArc` overload: allocates a scratch `BinPackingBuffer` and
forwards to the buffer-threading method.
"""
function _edge_incremental_cost(
    arc::NetworkArc, existing, new_comms::Vector{C}, sel::AbstractModeSelector
) where {C<:LightCommodity}
    return _edge_incremental_cost(BinPackingBuffer(), arc, existing, new_comms, sel)
end

"""
$TYPEDSIGNATURES

Buffer-free `MultiModalArc` overload: allocates a scratch `BinPackingBuffer` and
forwards to the buffer-threading method.
"""
function _edge_incremental_cost(
    arc::MultiModalArc, existing, new_comms::Vector{C}, sel::AbstractModeSelector
) where {C<:LightCommodity}
    return _edge_incremental_cost(BinPackingBuffer(), arc, existing, new_comms, sel)
end

# ============================================================================
# Relaxed lower-bound cost
#
# The optimistic counterpart of `_edge_incremental_cost`: each mode's increment
# comes from `lower_bound_incremental_cost` (fractional bin counts, no capacity
# ceiling). The only feasibility gate is on the batch's own size: an order's
# commodities always travel together on one edge, so a batch that alone exceeds
# a mode's capacity is infeasible in every solution and is priced `Inf`
# (existing load on the mode is otherwise ignored, keeping the bound
# order-independent and a valid relaxation). `NetworkArc` forwards to its
# single mode, and `MultiModalArc` + `CheapestMode` takes the minimum over
# modes. Used by the lower-bound and filtering strategies.
# ============================================================================

"""
$TYPEDSIGNATURES

Empty `NetworkArc` lower bound: relaxed increment of the order against no load,
gated on the order alone fitting the arc.
"""
function _edge_lower_bound_cost(
    arc::NetworkArc, ::Nothing, order::Order, ::AbstractModeSelector
)
    _mode_has_capacity(arc, 0.0, order.total_size) || return Inf
    return lower_bound_incremental_cost_with_order(arc.cost, nothing, order)
end

"""
$TYPEDSIGNATURES

Loaded `NetworkArc` lower bound: relaxed increment against the existing
commodities, gated on the order alone (ignoring existing load) fitting the arc.
"""
function _edge_lower_bound_cost(
    arc::NetworkArc, existing::SingleAssignment, order::Order, ::AbstractModeSelector
)
    _mode_has_capacity(arc, 0.0, order.total_size) || return Inf
    return lower_bound_incremental_cost_with_order(arc.cost, existing.commodities, order)
end

"""
$TYPEDSIGNATURES

Empty `MultiModalArc` lower bound under `CheapestMode`: minimum relaxed
increment over modes, each against no load and gated on the order alone
fitting that mode.
"""
function _edge_lower_bound_cost(arc::MultiModalArc, ::Nothing, order::Order, ::CheapestMode)
    return minimum(
        if _mode_has_capacity(mode, 0.0, order.total_size)
            lower_bound_incremental_cost_with_order(mode.cost, nothing, order)
        else
            Inf
        end for mode in arc.modes
    )
end

"""
$TYPEDSIGNATURES

Loaded `MultiModalArc` lower bound under `CheapestMode`: minimum relaxed
increment over modes, each against that mode's existing commodities and gated
on the order alone (ignoring existing load) fitting that mode.
"""
function _edge_lower_bound_cost(
    arc::MultiModalArc, existing::MultiAssignment, order::Order, ::CheapestMode
)
    return minimum(
        if _mode_has_capacity(arc.modes[i], 0.0, order.total_size)
            lower_bound_incremental_cost_with_order(
                arc.modes[i].cost, existing.per_mode[i].commodities, order
            )
        else
            Inf
        end for i in eachindex(arc.modes)
    )
end

# ============================================================================
# Node-cost incremental helpers
#
# Shared by `compute_ttg_edge_incremental_cost` and
# `compute_ttg_edge_lower_bound_cost`. `existing` is the (possibly absent) edge
# assignment already at the head node, the node cost is evaluated on its full
# load (see `_node_load`), never on a single mode's slot.
# ============================================================================

@inline function _node_incremental_cost(
    ::NoNodeCost, _, ::Vector{<:LightCommodity}, ::Float64
)
    return 0.0
end
@inline function _node_incremental_cost(
    f::LinearNodeCost, _, ::Vector{<:LightCommodity}, s::Float64
)
    return f.cost_per_unit_size * s
end
"""
$TYPEDSIGNATURES

Marginal head-node cost of routing `new` (with precomputed total size `s`) onto an
edge already carrying `existing`. Explicit `NoNodeCost`/`LinearNodeCost`
specializations avoid the `evaluate` allocation on the hot routing path, other node
costs fall back to `incremental_cost`.
"""
function _node_incremental_cost(
    f::AbstractNodeCostFunction, existing, new::Vector{C}, ::Float64
) where {C<:LightCommodity}
    load = isnothing(existing) ? C[] : _node_load(existing)
    return incremental_cost(f, load, new)
end

@inline function _node_lower_bound_incremental_cost(
    ::NoNodeCost, _, ::Vector{<:LightCommodity}, ::Float64
)
    return 0.0
end
@inline function _node_lower_bound_incremental_cost(
    f::LinearNodeCost, _, ::Vector{<:LightCommodity}, s::Float64
)
    return f.cost_per_unit_size * s
end
"""
$TYPEDSIGNATURES

Lower-bound counterpart of [`_node_incremental_cost`](@ref): the relaxed marginal
head-node cost of routing `new` (with precomputed total size `s`) onto an edge already
carrying `existing`.
"""
function _node_lower_bound_incremental_cost(
    f::AbstractNodeCostFunction, existing, new::Vector{C}, ::Float64
) where {C<:LightCommodity}
    load = isnothing(existing) ? C[] : _node_load(existing)
    return lower_bound_incremental_cost(f, load, new)
end
