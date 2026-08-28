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
    cache = instance.index_cache

    # Shortcut arc: same spatial node on both endpoints.
    if cache.ttg_code_to_spatial_code[u_ttg_code] ==
        cache.ttg_code_to_spatial_code[v_ttg_code]
        return 0.0
    end
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
        su = cache.tsg_code_to_spatial_code[u_tsg]
        sv = cache.tsg_code_to_spatial_code[v_tsg]
        arc = get(cache.spatial_pair_to_arc, (su, sv), nothing)
        if arc === nothing
            @warn "TSG edge ($(MetaGraphsNext.label_for(instance.time_space_graph.graph, u_tsg)) -> $(MetaGraphsNext.label_for(instance.time_space_graph.graph, v_tsg))) does not exist!"
            return Inf # Infeasible for this bundle
        end

        edge = (u_tsg, v_tsg)
        existing_assignment = get(current_solution.assignments, edge, nothing)
        new_total_size = order.total_size
        total_incremental_cost += _edge_incremental_cost(
            buffer,
            arc,
            existing_assignment,
            order.commodities,
            mode_selector;
            packing=packing,
            new_total_size=new_total_size,
        )

        # Destination-node cost via fast path when available.
        node_cost = cache.spatial_code_to_node_cost[sv]
        total_incremental_cost += incremental_cost_with_size(
            node_cost, order.commodities, order.commodities, new_total_size
        )
    end

    if !isempty(instance.travel_time_graph.cost_scaling)
        su = cache.ttg_code_to_spatial_code[u_ttg_code]
        sv = cache.ttg_code_to_spatial_code[v_ttg_code]
        factor = get(instance.travel_time_graph.cost_scaling, (su, sv), 1.0)
        total_incremental_cost *= factor
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
applied instead of the fractional formula.
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

    cache = instance.index_cache
    ng = instance.network_graph.graph
    su = cache.ttg_code_to_spatial_code[u_ttg_code]
    sv = cache.ttg_code_to_spatial_code[v_ttg_code]

    # Shortcut arc: same spatial node on both endpoints.
    if su == sv
        return 0.0
    end

    # Direct arc dispatch: bundle's origin -> destination.
    u_id = MetaGraphsNext.label_for(ng, su)
    v_id = MetaGraphsNext.label_for(ng, sv)
    if u_id == bundle.origin_id && v_id == bundle.destination_id
        return _direct_arc_lb_cost(bundle, instance, u_ttg_code, v_ttg_code, mode_selector)
    end
    total = 0.0
    # Each order in a bundle has a distinct delivery time step in
    # 1:time_horizon_length, so two orders cannot alias modulo the horizon and
    # therefore project to distinct TSG edges on this arc even under wrap_time
    # (verified: zero collisions). The cost is an additive sum over orders.
    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_code_to_spatial_code[u_tsg]
        sv = cache.tsg_code_to_spatial_code[v_tsg]
        arc = get(cache.spatial_pair_to_arc, (su, sv), nothing)
        if arc === nothing
            @warn "TSG edge ($(MetaGraphsNext.label_for(instance.time_space_graph.graph, u_tsg)) -> $(MetaGraphsNext.label_for(instance.time_space_graph.graph, v_tsg))) does not exist!"
            return Inf
        end
        edge = (u_tsg, v_tsg)
        existing = get(current_solution.assignments, edge, nothing)
        total += _edge_lower_bound_cost(arc, existing, order.commodities, mode_selector)

        node_cost = cache.spatial_code_to_node_cost[sv]
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
`cost_per_unit_size * order_size` on linear arcs).Used internally by
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
        su = cache.tsg_code_to_spatial_code[u_tsg]
        sv = cache.tsg_code_to_spatial_code[v_tsg]
        arc = get(cache.spatial_pair_to_arc, (su, sv), nothing)
        if arc === nothing
            @warn "TSG edge ($(MetaGraphsNext.label_for(instance.time_space_graph.graph, u_tsg)) -> $(MetaGraphsNext.label_for(instance.time_space_graph.graph, v_tsg))) does not exist!"
            return Inf
        end
        order_size = order.total_size
        total += _direct_arc_order_lb_cost(
            arc, order_size, order.commodities, mode_selector
        )

        # Destination-node cost on the direct arc, charged once per order.
        # Per-order incremental: existing is empty (LB is against empty solution).
        node_cost = cache.spatial_code_to_node_cost[sv]
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
# against an empty existing-set so SumArcCost terms like LinearArcCost and
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
    cache = instance.index_cache
    ng = instance.network_graph.graph
    u_id = MetaGraphsNext.label_for(ng, cache.ttg_code_to_spatial_code[u_ttg_code])
    v_id = MetaGraphsNext.label_for(ng, cache.ttg_code_to_spatial_code[v_ttg_code])
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
        su = cache.ttg_code_to_spatial_code[u_code]
        sv = cache.ttg_code_to_spatial_code[v_code]

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

"""
$TYPEDSIGNATURES

Create a `Vector{<:BinPackingBuffer}` with one buffer per thread. In the
parallel cost-matrix update the arcs are split into at most `length(pool)`
chunks and each parallel task borrows a distinct buffer by chunk ordinal, so
buffers are reused across calls without Channel contention or concurrent
resizes.
"""
function create_buffer_pool(n::Int=Threads.maxthreadid())
    return [BinPackingBuffer() for _ in 1:n]
end

"""
$TYPEDSIGNATURES

Parallel version of `update_bundle_cost_matrix!`. Splits the bundle arcs into
`min(length(buffer_pool), length(bundle_arcs))` contiguous chunks with
OhMyThreads `@tasks` (one task per chunk), each task using its own
`BinPackingBuffer` from `buffer_pool` indexed by chunk ordinal. Because a
buffer is owned by a single task for the whole loop, the pattern is safe under
task migration and never resizes a buffer concurrently.

Reads from `current_solution.assignments` are thread-safe (read-only Dict
lookups). Writes to `ttg.cost_matrix` are thread-safe because each arc maps
to a distinct structural nonzero in the sparse matrix.

Falls back to sequential `update_bundle_cost_matrix!` when only one thread
is available.
"""
function parallel_update_bundle_cost_matrix!(
    current_solution::Solution,
    instance::Instance,
    bundle::Bundle,
    bundle_arcs::Vector{Tuple{Int,Int}},
    mode_selector::AbstractModeSelector,
    buffer_pool::Vector{<:BinPackingBuffer};
    cost_fn::Function=compute_ttg_edge_incremental_cost,
    packing::Symbol=:frozen,
)
    if Threads.nthreads() <= 1
        update_bundle_cost_matrix!(
            current_solution,
            instance,
            bundle,
            bundle_arcs,
            mode_selector;
            cost_fn,
            buffer=buffer_pool[1],
            packing,
        )
        return nothing
    end

    ttg = instance.travel_time_graph
    cache = instance.index_cache
    ng = instance.network_graph.graph

    fn = Set{Int}(MetaGraphsNext.code_for(ng, id) for id in bundle.forbidden_nodes)
    fa = Set{Tuple{Int,Int}}(
        (MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)) for
        (u, v) in bundle.forbidden_arcs
    )

    fill!(SparseArrays.nonzeros(ttg.cost_matrix), Inf)
    isempty(bundle_arcs) && return nothing

    # Split the arcs into `nchunks` contiguous chunks and give each parallel
    # task its own `BinPackingBuffer` from `buffer_pool`, indexed by the chunk
    # ordinal (not `threadid()`). With `chunking = false` there is exactly one
    # task per chunk, so each buffer is owned by a single task for the whole
    # loop: safe under task migration, never resized concurrently, and the pool
    # is reused across calls (no per-call allocation).
    nchunks = min(length(buffer_pool), length(bundle_arcs))
    @tasks for (chunk_id, arc_indices) in
               enumerate(index_chunks(eachindex(bundle_arcs); n=nchunks))
        @set chunking = false
        buf = buffer_pool[chunk_id]
        for i in arc_indices
            (u_code, v_code) = bundle_arcs[i]
            su = cache.ttg_code_to_spatial_code[u_code]
            sv = cache.ttg_code_to_spatial_code[v_code]

            c = if (su, sv) in fa || su in fn || sv in fn
                Inf
            else
                cost_fn(
                    current_solution,
                    instance,
                    bundle,
                    u_code,
                    v_code,
                    mode_selector;
                    buffer=buf,
                    packing,
                )
            end
            ttg.cost_matrix[u_code, v_code] = c
        end
    end
    return nothing
end

function parallel_update_bundle_cost_matrix!(
    current_solution::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector,
    buffer_pool::Vector{<:BinPackingBuffer};
    cost_fn::Function=compute_ttg_edge_incremental_cost,
    packing::Symbol=:frozen,
)
    return parallel_update_bundle_cost_matrix!(
        current_solution,
        instance,
        instance.bundles[bundle_idx],
        instance.travel_time_graph.bundle_arcs[bundle_idx],
        mode_selector,
        buffer_pool;
        cost_fn,
        packing,
    )
end
