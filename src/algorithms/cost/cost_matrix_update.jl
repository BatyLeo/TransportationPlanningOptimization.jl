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

Like `compute_ttg_edge_lower_bound_cost`, but on the bundle's direct arc
(spatial endpoints equal to `bundle.origin_id` / `bundle.destination_id`) it
charges the *integer* bin count (via `incremental_cost`). The result is the
cost a bundle would pay if it shared bins for free on every multi-hop arc but
paid for its own bins on its direct route. Path lengths of 2 (origin to
destination) after this update mean the relaxed optimum is the direct arc,
which is the signal used by `extract_filtered_instance`.

# Note on direct-arc detection

This implementation detects a direct arc by spatial-endpoint equality with
the routed bundle's `(origin_id, destination_id)`. The Renault reference
implementation (`Algorithms/Utils/lb_utils.jl:lb_filtering_transport_units`)
uses an arc-type tag instead (`arcData.type == :direct`), which is a property
of the arc itself, independent of which bundle is being routed.

The two rules agree when each bundle has at most one direct arc and no
`:direct`-typed arc exists between non-matching endpoints. This holds on the
inbound CSVs in `test/public/`. They diverge once the network models multiple
`:direct`-typed arcs not endpoint-matching the routed bundle, in which case
Renault charges integer bins on all of them for the routed bundle, while this
implementation charges integer only on the bundle's specific OD pair.

A future task can expose `is_direct_for(arc, bundle)` dispatched on
`AbstractNetworkArc` to make the rule data-driven once the package gains an
arc-type taxonomy. Out of scope for now.
"""
function compute_ttg_edge_filtering_cost(
    current_solution::Solution{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
) where {C}
    u_id = MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)[1]
    v_id = MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code)[1]
    if u_id == bundle.origin_id && v_id == bundle.destination_id
        return compute_ttg_edge_incremental_cost(
            current_solution,
            instance,
            bundle,
            u_ttg_code,
            v_ttg_code,
            mode_selector;
            buffer,
        )
    else
        return compute_ttg_edge_lower_bound_cost(
            current_solution,
            instance,
            bundle,
            u_ttg_code,
            v_ttg_code,
            mode_selector;
            buffer,
        )
    end
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
