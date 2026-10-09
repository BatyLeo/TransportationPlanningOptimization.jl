"""
$TYPEDSIGNATURES

Integer spatial codes of the forbidden nodes and arcs of `bundle`. Ids absent from the
network graph are skipped. The input commodities are validated against the user nodes when the
instance is built, so such an id is a node dropped by an instance extraction (for example an
unused endpoint copy), it can no longer be traversed.
"""
function _forbidden_codes(ng, bundle::Bundle)
    fn = Set{Int}(
        MetaGraphsNext.code_for(ng, id) for id in bundle.forbidden_nodes if haskey(ng, id)
    )
    fa = Set{Tuple{Int,Int}}(
        (MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)) for
        (u, v) in bundle.forbidden_arcs if haskey(ng, u) && haskey(ng, v)
    )
    return fn, fa
end

"""
$TYPEDSIGNATURES

Compute the incremental cost of a TravelTimeGraph edge for a specific bundle,
considering all its orders and their projections to the TimeSpaceGraph.
"""
function compute_ttg_edge_incremental_cost(
    current_solution::SolutionState{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    empty_counts::Union{Nothing,Vector{EmptyPackCounts}}=nothing,
) where {C}
    cache = instance.index_cache

    # Shortcut arc: same spatial node on both endpoints.
    su0 = cache.ttg_code_to_spatial_code[u_ttg_code]
    sv0 = cache.ttg_code_to_spatial_code[v_ttg_code]
    su0 == sv0 && return 0.0

    # The TTG edge has a single spatial head node shared by every order's
    # projection, so the node-cost function is looked up once here.
    node_f = cache.spatial_code_to_node_cost[sv0]
    arc_part = 0.0
    node_part = 0.0
    edge_key = ttg_edge_key(cache, u_ttg_code, v_ttg_code)
    arc = get(cache.edge_group_to_arc, edge_key, nothing)
    if isnothing(arc)
        @warn "TTG edge ($(MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)) -> $(MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code))) has no network arc!"
        return Inf # Infeasible for this bundle
    end
    # A virtual arc carries no cost and its head is a hub, which must not be charged.
    _is_virtual(arc) && return 0.0

    # Each order in a bundle has a distinct delivery time step in
    # 1:time_horizon_length, so two orders differ by less than the horizon and
    # cannot alias modulo it. They therefore project to distinct TSG edges on this
    # arc even under wrap_time, so no grouping is needed to combine commodities on
    # a shared edge (verified: zero collisions over ~9.5M projections on medium and
    # large, both wrap_time). The cost is an additive sum over orders.
    for (k, order) in enumerate(bundle.orders)
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)

        edge = (u_tsg, v_tsg)
        existing_assignment = get(current_solution.assignments, edge, nothing)
        # A vacated edge keeps its emptied entry: treat it as unused to reuse the empty counts.
        if !isnothing(existing_assignment) &&
            _assignment_commodity_count(existing_assignment) == 0
            existing_assignment = nothing
        end
        new_total_size = order.total_size
        arc_part += _edge_incremental_cost(
            buffer,
            arc,
            existing_assignment,
            order.commodities,
            mode_selector;
            new_total_size=new_total_size,
            empty_counts=isnothing(empty_counts) ? nothing : empty_counts[k],
        )
        node_part += _node_incremental_cost(
            node_f, existing_assignment, order.commodities, new_total_size
        )
    end

    # Slope scaling is an arc-only relaxation heuristic, node costs are never scaled.
    if !isempty(instance.travel_time_graph.cost_scaling)
        factor = get(instance.travel_time_graph.cost_scaling, edge_key, 1.0)
        arc_part *= factor
    end

    return arc_part + node_part
end

"""
$TYPEDSIGNATURES

Whether the spatial edge `su -> sv` joins the origin and the destination of `bundle`, where
the origin (destination) is matched by its own node or by the hub that its endpoint copy is
linked to (see [`IndexCache`](@ref)).
"""
@inline function _is_direct_edge(cache::IndexCache, ng, bundle::Bundle, su::Int, sv::Int)
    return _is_bundle_end(cache.hub_origin_copy, ng, su, bundle.origin_id) &&
           _is_bundle_end(cache.hub_destination_copy, ng, sv, bundle.destination_id)
end

"""
$TYPEDSIGNATURES

Whether spatial node `s` is the node `end_id` of a bundle, or the hub of that node when it is
an endpoint copy (`copy_of` is `hub_origin_copy` or `hub_destination_copy` of the cache).
"""
@inline function _is_bundle_end(copy_of::Vector{Int}, ng, s::Int, end_id::String)
    MetaGraphsNext.label_for(ng, s) == end_id && return true
    c = copy_of[s]
    return c != 0 && MetaGraphsNext.label_for(ng, c) == end_id
end

"""
$TYPEDSIGNATURES

Compute the incremental cost of a TTG edge under the lower-bound relaxation.
Same projection logic as `compute_ttg_edge_incremental_cost`, but with
`_edge_lower_bound_cost` substituted for `_edge_incremental_cost`.

When the TTG edge is the bundle's direct arc (its spatial endpoints are the bundle's origin and
destination, or the hubs of their endpoint copies), the per-order ceil rule is
applied instead of the fractional formula. Virtual arcs of an endpoint split cost nothing.
"""
function compute_ttg_edge_lower_bound_cost(
    current_solution::SolutionState,
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    empty_counts=nothing,
)
    # The fractional bin counting needs none of `buffer`'s scratch, so `buffer` is
    # accepted only to keep the `cost_fn` call signature uniform. Likewise for
    # `empty_counts`.

    cache = instance.index_cache
    ng = instance.network_graph.graph
    su = cache.ttg_code_to_spatial_code[u_ttg_code]
    sv = cache.ttg_code_to_spatial_code[v_ttg_code]

    # Shortcut arc: same spatial node on both endpoints.
    if su == sv
        return 0.0
    end

    arc = ttg_edge_arc(cache, u_ttg_code, v_ttg_code)
    if isnothing(arc)
        @warn "TTG edge ($(MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)) -> $(MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code))) has no network arc!"
        return Inf
    end
    _is_virtual(arc) && return 0.0

    # Direct arc dispatch: bundle's origin -> destination.
    if _is_direct_edge(cache, ng, bundle, su, sv)
        return _direct_arc_lb_cost(bundle, instance, u_ttg_code, v_ttg_code, mode_selector)
    end
    total = 0.0
    # Each order in a bundle has a distinct delivery time step in
    # 1:time_horizon_length, so two orders cannot alias modulo the horizon and
    # therefore project to distinct TSG edges on this arc even under wrap_time
    # (verified: zero collisions). The cost is an additive sum over orders.
    node_f = cache.spatial_code_to_node_cost[sv]
    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        edge = (u_tsg, v_tsg)
        existing = get(current_solution.assignments, edge, nothing)
        total += _edge_lower_bound_cost(arc, existing, order, mode_selector)
        total += _node_lower_bound_incremental_cost(
            node_f, existing, order.commodities, order.total_size
        )
    end
    return total
end

"""
$TYPEDSIGNATURES

Lower-bound cost for the bundle's direct arc, summed per order. Mirrors
Renault's `get_lb_transport_units` for `:direct` arcs: each order contributes
`ceil(order_size / bin_capacity) * cost_per_bin` on bin-packing arcs (or
`cost_per_unit_size * order_size` on linear arcs). Used internally by
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
    arc = ttg_edge_arc(cache, u_ttg_code, v_ttg_code)
    if isnothing(arc)
        @warn "TTG edge ($(MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)) -> $(MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code))) has no network arc!"
        return Inf
    end
    _is_virtual(arc) && return 0.0
    node_f = cache.spatial_code_to_node_cost[cache.ttg_code_to_spatial_code[v_ttg_code]]
    total = 0.0
    for order in bundle.orders
        total += _direct_arc_order_lb_cost(arc, order, mode_selector)

        # Destination-node cost on the direct arc, charged once per order.
        # Per-order incremental: existing is empty (LB is against empty solution).
        total += _node_lower_bound_incremental_cost(
            node_f, nothing, order.commodities, order.total_size
        )
    end
    return total
end

function _direct_arc_order_lb_cost(arc::NetworkArc, order::Order, ::AbstractModeSelector)
    # Batch-only capacity gate: see the "Relaxed lower-bound cost" rationale in edge_cost.jl.
    _mode_has_capacity(arc, 0.0, order.total_size) || return Inf
    return _direct_arc_order_lb_cost(arc.cost, order)
end

# Two-argument size-based variants kept for direct callers that only need the
# formula (bin-packing). Auxiliary terms (carbon, stock, etc.) are only
# reachable via the `Order` overloads below.
function _direct_arc_order_lb_cost(cost::BinPackingArcCost, order_size::Real)
    return cost.cost_per_bin * ceil(order_size / cost.bin_capacity)
end

# `Order` overloads dispatched from `_direct_arc_lb_cost`. The size-only terms
# use the order's total size. Generic `AbstractArcCostFunction` terms fall back
# to `lower_bound_incremental_cost_with_order` against an empty existing-set so SumArcCost
# terms like LinearArcCost and StockArcCost can be evaluated on the order.
function _direct_arc_order_lb_cost(cost::BinPackingArcCost, order::Order)
    return _direct_arc_order_lb_cost(cost, order.total_size)
end

function _direct_arc_order_lb_cost(cost::AbstractArcCostFunction, order::Order)
    return lower_bound_incremental_cost_with_order(cost, nothing, order)
end

function _direct_arc_order_lb_cost(cost::SumArcCost, order::Order)
    return sum(_direct_arc_order_lb_cost(t, order) for t in cost.terms)
end

function _direct_arc_order_lb_cost(arc::MultiModalArc, order::Order, ::CheapestMode)
    # Batch-only capacity gate: see the "Relaxed lower-bound cost" rationale in edge_cost.jl.
    # Valid only when one mode carries the whole batch (CheapestMode), not when
    # FillThenSpillMode may split it across modes.
    return minimum(if _mode_has_capacity(mode, 0.0, order.total_size)
        _direct_arc_order_lb_cost(mode.cost, order)
    else
        Inf
    end for mode in arc.modes)
end

"""
$TYPEDSIGNATURES

Like `compute_ttg_edge_lower_bound_cost`, but on the bundle's direct arc
(spatial endpoints equal to `bundle.origin_id` / `bundle.destination_id`, or to the hubs of
their endpoint copies) it charges the *integer* bin count (via `incremental_cost`).
The result is the cost a bundle would pay if it shared bins for free on every multi-hop arc but
paid for its own bins on its direct route. A path made of the direct arc alone
(plus the virtual arcs of an endpoint split) after this update means the relaxed optimum is
the direct arc, which is the signal used by `extract_filtered_instance`.

# Note on direct-arc detection

This implementation detects a direct arc by spatial-endpoint equality with
the routed bundle's `(origin_id, destination_id)`, where an endpoint copy `v_o` or `v_d` of an
endpoint split matches through its hub `v` (see `_is_direct_edge`). The Renault reference
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
    current_solution::SolutionState{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    empty_counts=nothing,
) where {C}
    cache = instance.index_cache
    ng = instance.network_graph.graph
    su = cache.ttg_code_to_spatial_code[u_ttg_code]
    sv = cache.ttg_code_to_spatial_code[v_ttg_code]
    if _is_direct_edge(cache, ng, bundle, su, sv)
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

Whether every order of `bundle` still fits, under the hard capacities, on the TTG
edge `(u_ttg_code, v_ttg_code)` on top of the load already in `fixed_solution`.
`fixed_pairs` holds the spatial `(u, v)` code pairs that carry fixed load, so the
projections are only computed on those. Reuses the greedy capacity gate
(`_edge_incremental_cost` is `Inf` exactly when the batch does not fit), so `MultiModalArc` modes and `wrap_time` projections
are handled like in the construction.
"""
function _fits_fixed_load(
    fixed_solution::SolutionState,
    fixed_pairs::Set{Tuple{Int,Int}},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector,
    buffer::BinPackingBuffer,
)
    cache = instance.index_cache
    pair = (
        cache.ttg_code_to_spatial_code[u_ttg_code],
        cache.ttg_code_to_spatial_code[v_ttg_code],
    )
    pair in fixed_pairs || return true
    arc = ttg_edge_arc(cache, u_ttg_code, v_ttg_code)
    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        existing = get(fixed_solution.assignments, (u_tsg, v_tsg), nothing)
        isnothing(existing) && continue
        cost = _edge_incremental_cost(
            buffer, arc, existing, order.commodities, mode_selector
        )
        isfinite(cost) || return false
    end
    return true
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

`empty_counts` (one [`EmptyPackCounts`](@ref) per order of `bundle`) replaces the FFD
repack on empty arcs by a lookup, without changing any value. Returns `false` if the
absolute time `deadline` had passed at a check (every `DEADLINE_CHECK_EVERY` arcs) or, for
the parallel version, at the end of the sweep. The matrix may then be incomplete and
callers must not use it. Otherwise it returns `true`.
`cost_fn` is always called with an `empty_counts` keyword (possibly `nothing`), so a
custom `cost_fn` must accept it.
"""
function update_bundle_cost_matrix!(
    current_solution::SolutionState,
    instance::Instance,
    bundle::Bundle,
    bundle_arcs::Vector{Tuple{Int,Int}},
    mode_selector::AbstractModeSelector=CheapestMode();
    cost_fn::Function=compute_ttg_edge_incremental_cost,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    empty_counts::Union{Nothing,Vector{EmptyPackCounts}}=nothing,
    deadline::Float64=Inf,
)
    isnothing(empty_counts) || @assert length(empty_counts) == length(bundle.orders)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    ng = instance.network_graph.graph

    # Map the bundle's forbidden sets to integer spatial codes once (these sets
    # are usually empty or tiny), so the per-arc check stays on integers and
    # works for both real and virtual (two-node) bundles with no bundle index.
    fn, fa = _forbidden_codes(ng, bundle)

    fill!(SparseArrays.nonzeros(ttg.cost_matrix), Inf)

    for (i, (u_code, v_code)) in enumerate(bundle_arcs)
        i % DEADLINE_CHECK_EVERY == 0 && time() > deadline && return false
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
                empty_counts,
            )
        end
    end
    return true
end

"""
$TYPEDSIGNATURES

Compute and overwrite the `TravelTimeGraph` cost matrix entries for every arc
of bundle `bundle_idx`. Forwards to the lower-level overload with the bundle
and its precomputed `bundle_arcs[bundle_idx]`.
"""
function update_bundle_cost_matrix!(
    current_solution::SolutionState,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    cost_fn::Function=compute_ttg_edge_incremental_cost,
    buffer::BinPackingBuffer=BinPackingBuffer(),
)
    return update_bundle_cost_matrix!(
        current_solution,
        instance,
        instance.bundles[bundle_idx],
        instance.travel_time_graph.bundle_arcs[bundle_idx],
        mode_selector;
        cost_fn=cost_fn,
        buffer=buffer,
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

`empty_counts` and `deadline` behave as in `update_bundle_cost_matrix!`.
"""
function parallel_update_bundle_cost_matrix!(
    current_solution::SolutionState,
    instance::Instance,
    bundle::Bundle,
    bundle_arcs::Vector{Tuple{Int,Int}},
    mode_selector::AbstractModeSelector,
    buffer_pool::Vector{<:BinPackingBuffer};
    cost_fn::Function=compute_ttg_edge_incremental_cost,
    empty_counts::Union{Nothing,Vector{EmptyPackCounts}}=nothing,
    deadline::Float64=Inf,
)
    if Threads.nthreads() <= 1
        return update_bundle_cost_matrix!(
            current_solution,
            instance,
            bundle,
            bundle_arcs,
            mode_selector;
            cost_fn,
            buffer=buffer_pool[1],
            empty_counts,
            deadline,
        )
    end

    isnothing(empty_counts) || @assert length(empty_counts) == length(bundle.orders)

    ttg = instance.travel_time_graph
    cache = instance.index_cache
    ng = instance.network_graph.graph

    fn, fa = _forbidden_codes(ng, bundle)

    fill!(SparseArrays.nonzeros(ttg.cost_matrix), Inf)
    isempty(bundle_arcs) && return true

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
            i % DEADLINE_CHECK_EVERY == 0 && time() > deadline && break
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
                    empty_counts,
                )
            end
            ttg.cost_matrix[u_code, v_code] = c
        end
    end
    return time() <= deadline
end

function parallel_update_bundle_cost_matrix!(
    current_solution::SolutionState,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector,
    buffer_pool::Vector{<:BinPackingBuffer};
    cost_fn::Function=compute_ttg_edge_incremental_cost,
)
    return parallel_update_bundle_cost_matrix!(
        current_solution,
        instance,
        instance.bundles[bundle_idx],
        instance.travel_time_graph.bundle_arcs[bundle_idx],
        mode_selector,
        buffer_pool;
        cost_fn,
    )
end
