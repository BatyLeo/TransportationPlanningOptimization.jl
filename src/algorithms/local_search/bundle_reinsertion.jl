using Random

"""
$TYPEDSIGNATURES

Estimate how much cost would be removed if `bundle_idx`'s current path were
deleted from `sol`. The estimate is a proxy that sums each touched edge's
total cost weighted by the share of commodities on that edge that belong to
this bundle. It is not an exact value (a precise computation would require
running `remove_bundle_path!` and reading the actual delta), but it
correlates well with the actual delta and is O(arcs-on-path) instead of
O(arcs-on-path-times-commodities).

Used by `bundle_reinsertion_improvement!` to skip bundles whose potential
saving is below `cost_threshold`.
"""
function bundle_estimated_removal_cost(sol::Solution, instance::Instance, bundle_idx::Int)
    path = sol.bundle_paths[bundle_idx]
    isempty(path) && return 0.0
    bundle = instance.bundles[bundle_idx]
    total = 0.0
    for order in bundle.orders
        for k in 1:(length(path) - 1)
            u = project_to_time_space_graph(path[k], order, instance)
            v = project_to_time_space_graph(path[k + 1], order, instance)
            edge = (u, v)
            haskey(sol.assignments, edge) || continue
            assignment = sol.assignments[edge]
            commodities_count = _assignment_commodity_count(assignment)
            commodities_count == 0 && continue
            total += cost_of(assignment) * length(order.commodities) / commodities_count
        end
    end
    return total
end

_assignment_commodity_count(a::SingleAssignment) = length(a.commodities)
function _assignment_commodity_count(a::MultiAssignment)
    return sum(length(slot.commodities) for slot in a.per_mode; init=0)
end

"""
$TYPEDSIGNATURES

Combined cost computation and Dijkstra for a single bundle reinsertion.
Instead of pre-computing costs for all bundle arcs and then running Dijkstra,
this evaluates edge costs on-demand as Dijkstra settles each node and stops
as soon as the destination is reached. Only arcs on the shortest path tree
up to the destination are evaluated, roughly halving the number of cost
computations compared to the pre-compute-all approach.

Returns the `parents` vector (for use with `trace_path`).
"""
function _lazy_bundle_dijkstra!(
    sol::Solution{C},
    instance::Instance,
    bundle_idx::Int,
    origin::Int,
    dest::Int,
    mode_selector::AbstractModeSelector,
    buffer::BinPackingBuffer,
    bundle_adj::Dict{Int,Vector{Int}};
    packing::Symbol=:frozen,
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
) where {C}
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    bundle = instance.bundles[bundle_idx]

    # Convert forbidden sets to integer codes once (skip when empty,
    # which is the common case for inbound instances).
    ng = instance.network_graph.graph
    has_forbidden = !isempty(bundle.forbidden_nodes) || !isempty(bundle.forbidden_arcs)
    fn_codes = if has_forbidden
        Set{Int}(MetaGraphsNext.code_for(ng, id) for id in bundle.forbidden_nodes)
    else
        Set{Int}()
    end
    fa_codes = if has_forbidden
        Set{Tuple{Int,Int}}(
            (MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)) for
            (u, v) in bundle.forbidden_arcs
        )
    else
        Set{Tuple{Int,Int}}()
    end

    if workspace !== nothing
        _reset_workspace!(workspace, origin)
        dists = workspace.dists
        parents = workspace.parents
    else
        n = Graphs.nv(ttg.graph)
        dists = fill(Inf, n)
        parents = zeros(Int, n)
        dists[origin] = 0.0
    end

    heap = DataStructures.BinaryMinHeap{Tuple{Float64,Int}}()
    push!(heap, (0.0, origin))

    while !isempty(heap)
        d_u, u = pop!(heap)
        d_u > dists[u] && continue
        u == dest && break

        su = cache.ttg_code_to_spatial_code[u]
        for v in get(bundle_adj, u, Int[])
            sv = cache.ttg_code_to_spatial_code[v]

            if su == sv
                alt = d_u
            else
                if has_forbidden &&
                    ((su, sv) in fa_codes || su in fn_codes || sv in fn_codes)
                    continue
                end
                w = compute_ttg_edge_incremental_cost(
                    sol, instance, bundle, u, v, mode_selector; buffer, packing
                )
                alt = d_u + w
            end
            if alt < dists[v]
                dists[v] = alt
                parents[v] = u
                push!(heap, (alt, v))
            end
        end
    end

    return parents
end

"""
$TYPEDSIGNATURES

Attempt a single-bundle reinsertion. Snapshot the assignment state, remove the
bundle, compute the cost matrix against the bundle-free solution, run Dijkstra,
and compare the new path to the old one. When Dijkstra returns the same path
or no path, restore via snapshot. When a different path is found, add the new
path with full FFD repack and accept only if the net cost delta is strictly
negative (improvement greater than `COST_IMPROVEMENT_EPS`). Returns the cost
improvement (non-negative `Float64`).

When `remove_before_routing=false`, the bundle is left in the solution during
cost matrix computation (cheaper but less accurate). The bundle is only removed
when a genuinely different path is found, avoiding snapshot/restore overhead
for same-path and no-path cases. The accept/reject decision is always based on
actual cost deltas regardless of this flag.

Used by `bundle_reinsertion_improvement!` as its per-bundle inner step and by
`two_node_common_incremental!` as the refine step. Bundles whose path is
already empty return `0.0` without side effects.
"""
function _try_reinsert_bundle!(
    sol::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector;
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    bundle_adj::Union{Dict{Int,Vector{Int}},Nothing}=nothing,
    remove_before_routing::Bool=true,
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
    buffer_pool::Union{Vector{<:BinPackingBuffer},Nothing}=nothing,
    snapshot_cache::Union{Dict,Nothing}=nothing,
)
    isempty(sol.bundle_paths[bundle_idx]) && return 0.0
    ttg = instance.travel_time_graph
    origin = ttg.origin_codes[bundle_idx]
    dest = ttg.destination_codes[bundle_idx]

    old_path = copy(sol.bundle_paths[bundle_idx])

    snapshots = _snapshot_path_assignments(sol, instance, bundle_idx; cache=snapshot_cache)
    cost_removed = if remove_before_routing
        remove_bundle_path!(sol, instance, bundle_idx)
    else
        0.0
    end

    # When multiple threads are available, pre-compute all arc costs in
    # parallel and run standard Dijkstra. Otherwise, use lazy Dijkstra
    # (fewer arc evaluations, better for single-threaded).
    parents = if Threads.nthreads() > 1 && buffer_pool !== nothing
        parallel_update_bundle_cost_matrix!(
            sol, instance, bundle_idx, mode_selector, buffer_pool; packing=cost_packing
        )
        p, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=dest, workspace)
        p
    elseif bundle_adj !== nothing
        _lazy_bundle_dijkstra!(
            sol,
            instance,
            bundle_idx,
            origin,
            dest,
            mode_selector,
            buffer,
            bundle_adj;
            packing=cost_packing,
            workspace,
        )
    else
        update_bundle_cost_matrix!(
            sol, instance, bundle_idx, mode_selector; packing=cost_packing
        )
        p, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=dest)
        p
    end
    new_path = trace_path(parents, origin, dest)

    if isempty(new_path)
        if remove_before_routing
            _restore_path_assignments!(sol, bundle_idx, old_path, snapshots)
        end
        return 0.0
    end

    _remove_shortcuts_from_path!(new_path, ttg)

    if new_path == old_path
        if remove_before_routing
            _restore_path_assignments!(sol, bundle_idx, old_path, snapshots)
        end
        return 0.0
    end

    # When routing was done with the bundle in place, remove it now before
    # adding the new path. Re-snapshot to capture the current state.
    if !remove_before_routing
        snapshots = _snapshot_path_assignments(
            sol, instance, bundle_idx; cache=snapshot_cache
        )
        cost_removed = remove_bundle_path!(sol, instance, bundle_idx)
    end

    cost_added = add_bundle_path!(
        sol, instance, bundle_idx, new_path; mode_selector, packing
    )
    net_delta = cost_added + cost_removed
    if net_delta < -COST_IMPROVEMENT_EPS
        return -net_delta
    end

    remove_bundle_path!(sol, instance, bundle_idx)
    _restore_path_assignments!(sol, bundle_idx, old_path, snapshots)
    return 0.0
end

"""
$TYPEDSIGNATURES

For each bundle in turn, remove its current path, recompute the cost matrix
against the now-bundle-less solution, run Dijkstra, and accept the new path
only if its net cost delta is strictly negative (improvement greater than
`COST_IMPROVEMENT_EPS`). Otherwise restore the old path. Returns the total cost improvement
(a non-negative `Float64`).

Bundles whose path is already empty are skipped. The `time_limit` keyword
caps total wall time spent in the loop (the loop exits between bundles, not
mid-bundle).

When `cost_threshold > 0`, bundles whose
`bundle_estimated_removal_cost(sol, instance, i)` is at or below the
threshold are skipped without attempting a reinsertion. This is a cheap
filter that avoids running Dijkstra on bundles whose total cost contribution
is too small to yield a meaningful improvement.

Implementation note: uses the cost deltas returned by `remove_bundle_path!`
and `add_bundle_path!` to score each move in O(arcs-on-path) per candidate
rather than calling `cost(sol)` (which is O(|assignments|)).
"""
function bundle_reinsertion_improvement!(
    sol::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    time_limit::Real=Inf,
    cost_threshold::Real=0.0,
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
)
    saved = 0.0
    t_start = time()
    for i in eachindex(instance.bundles)
        time() - t_start > time_limit && break
        isempty(sol.bundle_paths[i]) && continue
        if cost_threshold > 0 &&
            bundle_estimated_removal_cost(sol, instance, i) <= cost_threshold
            continue
        end
        saved += _try_reinsert_bundle!(
            sol, instance, i, mode_selector; packing, cost_packing
        )
    end
    return saved
end

"""
$TYPEDSIGNATURES

One bundle-reintroduction step: pick a random bundle, skip it if its path is
empty or its `bundle_estimated_removal_cost` is below `cost_threshold`,
otherwise delegate to `_try_reinsert_bundle!`. Returns the per-step cost
improvement (`0.0` if skipped or move rejected).
"""
function _run_reintro_step!(
    sol::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector,
    rng::Random.AbstractRNG,
    cost_threshold::Float64,
    packing::Symbol,
    cost_packing::Symbol;
    buffer::BinPackingBuffer=BinPackingBuffer(),
    bundle_adjs::Union{Vector{Dict{Int,Vector{Int}}},Nothing}=nothing,
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
    buffer_pool::Union{Vector{<:BinPackingBuffer},Nothing}=nothing,
    snapshot_cache::Union{Dict,Nothing}=nothing,
)
    n = length(instance.bundles)
    n == 0 && return 0.0
    bundle_idx = rand(rng, 1:n)
    isempty(sol.bundle_paths[bundle_idx]) && return 0.0
    if cost_threshold > 0 &&
        bundle_estimated_removal_cost(sol, instance, bundle_idx) <= cost_threshold
        return 0.0
    end
    bundle_adj = bundle_adjs === nothing ? nothing : bundle_adjs[bundle_idx]
    return _try_reinsert_bundle!(
        sol,
        instance,
        bundle_idx,
        mode_selector;
        packing,
        cost_packing,
        buffer,
        bundle_adj,
        workspace,
        buffer_pool,
        snapshot_cache,
    )
end
