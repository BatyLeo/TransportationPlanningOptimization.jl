"""
$TYPEDSIGNATURES

Compute the additional cost of adding `new_commodities` to an arc that already contains
`existing_commodities`.
"""
function incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    # Default implementation: evaluate total and subtract
    all_commodities = vcat(existing_commodities, new_commodities)
    return evaluate(arc_f, all_commodities) - evaluate(arc_f, existing_commodities)
end

"""
$TYPEDSIGNATURES

Specialized for LinearArcCost for efficiency.
"""
function incremental_cost(
    arc_f::LinearArcCost, ::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    total_new_size = sum(c.size for c in new_commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_new_size
end

"""
$TYPEDSIGNATURES

Buffer-threaded variant of `incremental_cost`. The generic fallback ignores the
buffer and forwards to `incremental_cost`, so `LinearArcCost`, node costs, and
any other cheap cost function need no specialization. Only `BinPackingArcCost`
(and `SumArcCost`, which forwards to its unique bin-packing term) specialize
this to reuse the scratch buffer and avoid per-call allocation.
"""
function incremental_cost!(
    ::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing, new)
end

"""
$TYPEDSIGNATURES

Buffer-threaded variant of `incremental_cost` for node costs. Node costs are
cheap, so the buffer is ignored and the call forwards to `incremental_cost`.
"""
function incremental_cost!(
    ::BinPackingBuffer,
    node_f::AbstractNodeCostFunction,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return incremental_cost(node_f, existing, new)
end

"""
$TYPEDSIGNATURES

Return `true` if `v` is sorted in non-increasing (descending) order. Used to
skip a redundant `sort!` when a size run is already descending (the common case
once `Order.commodities` is pre-sorted at instance construction).
"""
function _is_desc(v::AbstractVector{Float64})
    @inbounds for i in 2:length(v)
        v[i - 1] < v[i] && return false
    end
    return true
end

"""
$TYPEDSIGNATURES

Incremental FFD bin cost of adding `new` to `existing` on a `BinPackingArcCost`
arc, reusing `buffer`. Equals `cost_per_bin * (FFD(existing union new) -
FFD(existing))`, identical to the generic fallback and to the sort-the-union
form, but it streams the descending two-way merge of the two runs into FFD
without materializing the union vector.

`Order.commodities` is kept sorted by size descending at instance construction
(see `build_instance`), so both the per-edge `new` run (one order's commodities
in the common case) and the `existing` run arrive pre-sorted. `new` is still
checked and sorted in place if needed (the `new_sizes` buffer slot doubles as
that scratch). `existing` is iterated lazily — when the descending invariant
holds, the loop iterates the commodity vector directly; otherwise a one-shot
sort over a fresh `Vector{Float64}` is taken (rare).
"""
function incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    isempty(new) && return 0.0
    @boundscheck _commodities_is_desc(new) ||
        throw(ArgumentError("`new` must be sorted descending by `.size`"))
    cap = Float64(arc_f.bin_capacity)

    # Existing run sizes, descending — materialized into `existing_sizes` so the
    # merge's hot loop reads from a tightly packed `Vector{Float64}`. Validated
    # against the descending invariant in debug builds.
    if isempty(existing)
        empty!(buffer.existing_sizes)
    else
        @boundscheck _commodities_is_desc(existing) ||
            throw(ArgumentError("`existing` must be sorted descending by `.size`"))
        resize!(buffer.existing_sizes, length(existing))
        @inbounds for (i, c) in enumerate(existing)
            buffer.existing_sizes[i] = c.size
        end
    end

    # When the caller passes `n_existing` (= `length(assignment.bins)`),
    # skip the standalone FFD-on-existing pass and trust the cached value.
    n_ex = if n_existing >= 0
        n_existing
    elseif isempty(existing)
        0
    else
        ffd_count!(buffer, cap, buffer.existing_sizes)
    end

    # FFD over the descending union of `existing_sizes` and `new`. The `new`
    # commodity vector is iterated directly via `c.size` — no `new_sizes`
    # scratch needed.
    empty!(buffer.remaining_capacities)
    _ffd_place_merged_with_commodities!(
        buffer.remaining_capacities, buffer.existing_sizes, new, cap
    )
    n_union = length(buffer.remaining_capacities)

    return arc_f.cost_per_bin * (n_union - n_ex)
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental cost of adding `new` onto the already committed bins
`existing_bins` on a `BinPackingArcCost` arc, reusing `buffer`. Equals
`cost_per_bin * (number of bins newly opened by first-fitting `new` onto the
frozen bins' remaining capacities)`. This is the STP packing semantics: the
committed bins are never re-packed and never re-sorted, only `new` is dropped
in via first-fit. Used under `packing == :frozen`.
"""
function frozen_incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    existing_bins::AbstractVector{<:Bin},
    new::Vector{C},
) where {C<:LightCommodity}
    isempty(new) && return 0.0
    cap = Float64(arc_f.bin_capacity)
    n_new = frozen_incremental_count!(buffer, cap, existing_bins, new)
    return arc_f.cost_per_bin * n_new
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental cost for `SumArcCost`. The unique `BinPackingArcCost`
term uses the frozen count against `existing_bins`. Every other term (carbon,
stock, etc.) is linear in volume, so its incremental cost is identical in both
packing modes and is computed against `existing_comms` via the plain
`incremental_cost`. The bin-packing term is excluded from that sum and replaced
by the frozen count, keeping the result consistent with the frozen commit.
"""
function frozen_incremental_cost!(
    buffer::BinPackingBuffer,
    c::SumArcCost,
    existing_bins::AbstractVector{<:Bin},
    existing_comms::Vector{C},
    new::Vector{C},
) where {C<:LightCommodity}
    total = 0.0
    for t in c.terms
        if t isa BinPackingArcCost
            total += frozen_incremental_cost!(buffer, t, existing_bins, new)
        else
            total += incremental_cost!(buffer, t, existing_comms, new)
        end
    end
    return total
end

"""
$TYPEDSIGNATURES

Buffer-threaded `incremental_cost!` for `SumArcCost`. Sums the per-term
incremental costs, forwarding the shared `buffer` to each term. The unique
`BinPackingArcCost` term reuses the buffer (its `incremental_cost!`
specialization), every other term falls back to its plain `incremental_cost`
through the generic `incremental_cost!`. The result is identical to the
sum-over-terms `incremental_cost(::SumArcCost, ...)`.
"""
function incremental_cost!(
    buffer::BinPackingBuffer,
    c::SumArcCost,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return _sum_incremental_cost_buf(buffer, c.terms, existing, new, n_existing)
end
@inline _sum_incremental_cost_buf(
    ::BinPackingBuffer, ::Tuple{}, ::Vector{C}, ::Vector{C}, ::Int
) where {C<:LightCommodity} = 0.0
@inline function _sum_incremental_cost_buf(
    buffer::BinPackingBuffer,
    terms::Tuple,
    existing::Vector{C},
    new::Vector{C},
    n_existing::Int,
) where {C<:LightCommodity}
    return incremental_cost!(buffer, first(terms), existing, new; n_existing) +
           _sum_incremental_cost_buf(buffer, Base.tail(terms), existing, new, n_existing)
end

"""
$TYPEDSIGNATURES

Lower-bound variant of `incremental_cost`. By default it forwards to
`incremental_cost`, so any new `AbstractArcCostFunction` subtype automatically
inherits a sane default. Specialize this for cost functions whose lower bound
differs from their actual cost (for example, `BinPackingArcCost`).
"""
function lower_bound_incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing_commodities, new_commodities)
end

"""
$TYPEDSIGNATURES

Lower-bound cost on a `BinPackingArcCost` arc using fractional bin counts
(no ceiling). The result is a continuous relaxation of the FFD cost. It is
not the cheapest path for an actual solver, but it is a valid lower bound
when summed across paths and used for filtering.
"""
function lower_bound_incremental_cost(
    arc_f::BinPackingArcCost, existing_commodities::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    existing_size = sum(c.size for c in existing_commodities; init=0.0)
    new_size = sum(c.size for c in new_commodities; init=0.0)
    n_bins_with = (existing_size + new_size) / arc_f.bin_capacity
    n_bins_without = existing_size / arc_f.bin_capacity
    return arc_f.cost_per_bin * (n_bins_with - n_bins_without)
end

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

"""
$TYPEDSIGNATURES

Compute the incremental cost of a TravelTimeGraph edge for a specific bundle,
considering all its orders and their projections to the TimeSpaceGraph.
"""
function compute_ttg_edge_incremental_cost(
    current_solution::Solution{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
) where {C}
    # IF it's a shortcut arc, return zero cost
    u_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)
    v_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code)
    if u_ttg_label[1] == v_ttg_label[1]
        return 0.0
    end

    cache = instance.index_cache
    total_incremental_cost = 0.0

    # Each order in a bundle has a distinct delivery time step in
    # 1:time_horizon_length, so two orders differ by less than the horizon and
    # cannot alias modulo it. They therefore project to distinct TSG edges on this
    # arc even under wrap_time, so no grouping is needed to combine commodities on
    # a shared edge (verified: zero collisions over ~9.5M projections on medium and
    # large, both wrap_time). The cost is an additive sum over orders.
    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        arc = get(cache.arc_of, (su, sv), nothing)
        if arc === nothing
            @warn "TSG edge ($(MetaGraphsNext.label_for(instance.time_space_graph.graph, u_tsg)) -> $(MetaGraphsNext.label_for(instance.time_space_graph.graph, v_tsg))) does not exist!"
            return Inf # Infeasible for this bundle
        end

        edge = (u_tsg, v_tsg)
        existing_assignment = get(current_solution.assignments, edge, nothing)
        total_incremental_cost += _edge_incremental_cost(
            buffer,
            arc,
            existing_assignment,
            order.commodities,
            mode_selector;
            packing=packing,
        )

        # Destination-node cost. Charged on the spatial destination of each
        # traversed arc, matching STP's `volume_stock_cost`
        # (ShipperTransportationPlanning.jl/src/Algorithms/Utils/greedy_utils.jl:23).
        node_cost = cache.node_cost_of[sv]
        existing_at_dst_node = if existing_assignment === nothing
            C[]
        elseif existing_assignment isa SingleAssignment
            # Stored vector, read-only (incremental_cost! does not mutate existing).
            existing_assignment.commodities
        else
            # MultiAssignment commodities_of is a lazy flatten, so materialize it.
            collect(commodities_of(existing_assignment))
        end
        total_incremental_cost += incremental_cost!(
            buffer, node_cost, existing_at_dst_node, order.commodities
        )
    end

    return total_incremental_cost
end

"""
$TYPEDSIGNATURES

Compute the incremental cost of a TTG edge under the lower-bound relaxation.
Same projection logic as `compute_ttg_edge_incremental_cost`, but with
`_edge_lower_bound_cost` substituted for `_edge_incremental_cost`.

When the TTG edge is the bundle's direct arc (spatial labels equal to
`(bundle.origin_id, bundle.destination_id)`), the per-order ceil rule is
applied instead of the fractional formula. This matches Renault's
`get_lb_transport_units`: a direct arc cannot be shared with other bundles,
so the fractional relaxation describes a fiction there, and the tighter
per-order ceil bound steers Dijkstra toward multi-hop consolidation when it
exists.
"""
function compute_ttg_edge_lower_bound_cost(
    current_solution::Solution{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
) where {C}
    # The lower-bound path is a fractional relaxation, not FFD bin packing, so
    # `packing` is accepted only to keep the `cost_fn` call signature uniform
    # with `compute_ttg_edge_incremental_cost`. It has no effect here.
    # The fractional bin counting needs none of `buffer`'s scratch, so `buffer` is
    # accepted only to keep the `cost_fn` call signature uniform.

    # IF it's a shortcut arc, return zero cost
    u_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)
    v_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code)
    if u_ttg_label[1] == v_ttg_label[1]
        return 0.0
    end

    # Direct arc dispatch: bundle's origin -> destination.
    if u_ttg_label[1] == bundle.origin_id && v_ttg_label[1] == bundle.destination_id
        return _direct_arc_lb_cost(bundle, instance, u_ttg_code, v_ttg_code, mode_selector)
    end

    cache = instance.index_cache
    total = 0.0
    # Each order in a bundle has a distinct delivery time step in
    # 1:time_horizon_length, so two orders cannot alias modulo the horizon and
    # therefore project to distinct TSG edges on this arc even under wrap_time
    # (verified: zero collisions). The cost is an additive sum over orders.
    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        arc = get(cache.arc_of, (su, sv), nothing)
        if arc === nothing
            @warn "TSG edge ($(MetaGraphsNext.label_for(instance.time_space_graph.graph, u_tsg)) -> $(MetaGraphsNext.label_for(instance.time_space_graph.graph, v_tsg))) does not exist!"
            return Inf
        end
        edge = (u_tsg, v_tsg)
        existing = get(current_solution.assignments, edge, nothing)
        total += _edge_lower_bound_cost(arc, existing, order.commodities, mode_selector)

        # Destination-node cost. Charged on the spatial destination of each
        # traversed arc, matching STP's `volume_stock_cost`
        # (ShipperTransportationPlanning.jl/src/Algorithms/Utils/greedy_utils.jl:23).
        node_cost = cache.node_cost_of[sv]
        existing_at_dst_node = if existing === nothing
            C[]
        elseif existing isa SingleAssignment
            # Stored vector, read-only (no copy needed).
            existing.commodities
        else
            # MultiAssignment commodities_of is a lazy flatten, so materialize it.
            collect(commodities_of(existing))
        end
        total += lower_bound_incremental_cost(
            node_cost, existing_at_dst_node, order.commodities
        )
    end
    return total
end

"""
$TYPEDSIGNATURES

Lower-bound cost for the bundle's direct arc, summed per order. Mirrors
Renault's `get_lb_transport_units` for `:direct` arcs: each order contributes
`ceil(order_size / bin_capacity) * cost_per_bin` on bin-packing arcs (or
`cost_per_unit_size * order_size` on linear arcs). Existing arc state is
ignored, matching STP behavior. Used internally by
`compute_ttg_edge_lower_bound_cost` when the TTG edge is identified as the
bundle's direct arc.
"""
function _direct_arc_lb_cost(
    bundle::Bundle,
    instance::Instance,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector,
)
    cache = instance.index_cache
    total = 0.0
    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        arc = get(cache.arc_of, (su, sv), nothing)
        if arc === nothing
            @warn "TSG edge ($(MetaGraphsNext.label_for(instance.time_space_graph.graph, u_tsg)) -> $(MetaGraphsNext.label_for(instance.time_space_graph.graph, v_tsg))) does not exist!"
            return Inf
        end
        order_size = sum(c.size for c in order.commodities; init=0.0)
        total += _direct_arc_order_lb_cost(
            arc, order_size, order.commodities, mode_selector
        )

        # Destination-node cost on the direct arc, charged once per order.
        # Per-order incremental: existing is empty (LB is against empty solution).
        node_cost = cache.node_cost_of[sv]
        total += lower_bound_incremental_cost(
            node_cost, eltype(order.commodities)[], order.commodities
        )
    end
    return total
end

function _direct_arc_order_lb_cost(
    arc::NetworkArc,
    order_size::Real,
    commodities::Vector{<:LightCommodity},
    ::AbstractModeSelector,
)
    return _direct_arc_order_lb_cost(arc.cost, order_size, commodities)
end

# Two-argument variants kept for direct callers that only need the size-based
# formula (linear, bin-packing). Auxiliary terms (carbon, stock, etc.) cannot
# be evaluated without commodities and are only reachable via the
# three-argument overloads below.
function _direct_arc_order_lb_cost(cost::BinPackingArcCost, order_size::Real)
    return cost.cost_per_bin * ceil(order_size / cost.bin_capacity)
end

function _direct_arc_order_lb_cost(cost::LinearArcCost, order_size::Real)
    return cost.cost_per_unit_size * order_size
end

# Three-argument overloads dispatched from `_direct_arc_lb_cost`. The
# size-only terms ignore the commodities vector. Generic
# `AbstractArcCostFunction` terms fall back to `lower_bound_incremental_cost`
# against an empty existing-set so SumArcCost terms like CarbonArcCost and
# StockArcCost can be evaluated using the order's commodities.
function _direct_arc_order_lb_cost(
    cost::BinPackingArcCost, order_size::Real, ::Vector{<:LightCommodity}
)
    return _direct_arc_order_lb_cost(cost, order_size)
end

function _direct_arc_order_lb_cost(
    cost::LinearArcCost, order_size::Real, ::Vector{<:LightCommodity}
)
    return _direct_arc_order_lb_cost(cost, order_size)
end

function _direct_arc_order_lb_cost(
    cost::AbstractArcCostFunction, ::Real, commodities::Vector{C}
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(cost, C[], commodities)
end

function _direct_arc_order_lb_cost(
    cost::SumArcCost, order_size::Real, commodities::Vector{<:LightCommodity}
)
    return sum(_direct_arc_order_lb_cost(t, order_size, commodities) for t in cost.terms)
end

function _direct_arc_order_lb_cost(
    arc::MultiModalArc,
    order_size::Real,
    commodities::Vector{<:LightCommodity},
    ::AbstractModeSelector,
)
    return minimum(
        _direct_arc_order_lb_cost(mode.cost, order_size, commodities) for mode in arc.modes
    )
end

"""
$TYPEDSIGNATURES

Lower-level overload that accepts a `bundle` and its `bundle_arcs` set
directly, bypassing the `instance.bundles[bundle_idx]` lookup. Used by
`two_node_common_incremental!` (Phase 3.7) to compute the cost matrix for a
virtual merged bundle that has no index in `instance.bundles`.

The `cost_fn` keyword selects which per-edge cost computation is used. The
default, `compute_ttg_edge_incremental_cost`, preserves greedy behaviour.
Lower-bound callers can pass `cost_fn=compute_ttg_edge_lower_bound_cost`.

The `buffer` keyword (defaulting to a fresh `BinPackingBuffer`) is forwarded to
`cost_fn` so a sweep can create one buffer and reuse it across all bundles and
arcs, eliminating the per-arc bin-packing allocations. Ad-hoc callers that omit
it get a fresh buffer and behave exactly as before.
"""
function update_bundle_cost_matrix!(
    current_solution::Solution,
    instance::Instance,
    bundle::Bundle,
    bundle_arcs::Vector{Tuple{Int,Int}},
    mode_selector::AbstractModeSelector=CheapestMode();
    cost_fn::Function=compute_ttg_edge_incremental_cost,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    ng = instance.network_graph.graph

    # Map the bundle's forbidden sets to integer spatial codes once (these sets
    # are usually empty or tiny), so the per-arc check stays on integers and
    # works for both real and virtual (two-node) bundles with no bundle index.
    fn = Set{Int}(MetaGraphsNext.code_for(ng, id) for id in bundle.forbidden_nodes)
    fa = Set{Tuple{Int,Int}}(
        (MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)) for
        (u, v) in bundle.forbidden_arcs
    )

    fill!(SparseArrays.nonzeros(ttg.cost_matrix), Inf)

    for (u_code, v_code) in bundle_arcs
        su = cache.ttg_spatial[u_code]
        sv = cache.ttg_spatial[v_code]

        if (su, sv) in fa || su in fn || sv in fn
            ttg.cost_matrix[u_code, v_code] = Inf
        else
            ttg.cost_matrix[u_code, v_code] = cost_fn(
                current_solution,
                instance,
                bundle,
                u_code,
                v_code,
                mode_selector;
                buffer,
                packing,
            )
        end
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Compute and overwrite the `TravelTimeGraph` cost matrix entries for every arc
of bundle `bundle_idx`. Forwards to the lower-level overload with the bundle
and its precomputed `bundle_arcs[bundle_idx]`.
"""
function update_bundle_cost_matrix!(
    current_solution::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    cost_fn::Function=compute_ttg_edge_incremental_cost,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
)
    return update_bundle_cost_matrix!(
        current_solution,
        instance,
        instance.bundles[bundle_idx],
        instance.travel_time_graph.bundle_arcs[bundle_idx],
        mode_selector;
        cost_fn=cost_fn,
        buffer=buffer,
        packing=packing,
    )
end
