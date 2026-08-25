using Random

"""
$TYPEDEF

Result returned by [`local_search!`](@ref).

# Fields
$TYPEDFIELDS
"""
struct LocalSearchResult
    "Total cost improvement (accepted moves plus final repack)"
    saved::Float64
    "Cost after local search (`start_cost - saved`)"
    final_cost::Float64
    "Number of iterations performed"
    n_iter::Int
    "Final no-improvement streak length"
    n_no_improv::Int
    "Wall-time samples from start, taken every `sample_every` iterations"
    timestamps::Vector{Float64}
    "Cost snapshots at the same iteration counts as `timestamps`"
    costs::Vector{Float64}
    "Iteration counts at each sample"
    iters_at_sample::Vector{Int}
end

function Base.show(io::IO, r::LocalSearchResult)
    return print(
        io,
        "LocalSearchResult: saved $(round(r.saved; digits=2)) in $(r.n_iter) iterations (final cost: $(round(r.final_cost; digits=2)))",
    )
end

"""
$TYPEDSIGNATURES

Repack every `BinPackingArcCost` assignment in `sol` using whichever of
First-Fit Decreasing (FFD) and Best-Fit Decreasing (BFD) produces fewer
bins. Each arc is gated by `tentative_bin_count` and
`tentative_best_fit_count` to predict both bin counts up front. The bin
assignments are only materialized when at least one of the two heuristics
strictly improves on the currently stored bin count. On ties between FFD
and BFD, FFD is preferred (it has a smaller constant factor).

Non-`BinPackingArcCost` assignments are left untouched. The returned total
cost improvement is always non-negative.
"""
function bin_packing_improvement!(sol::Solution, instance::Instance)
    tsg = instance.time_space_graph
    saved = 0.0
    for (edge, assignment) in sol.assignments
        u_label = MetaGraphsNext.label_for(tsg.graph, edge[1])
        v_label = MetaGraphsNext.label_for(tsg.graph, edge[2])
        arc = tsg.graph[u_label, v_label]
        saved += _repack_assignment!(assignment, arc)
    end
    return saved
end

function _repack_assignment!(a::SingleAssignment, arc::NetworkArc)
    arc.cost isa BinPackingArcCost || return 0.0
    ps = a.sorted
    ffd_count = tentative_bin_count(arc.cost, a.commodities; presorted=ps)
    bfd_count = tentative_best_fit_count(arc.cost, a.commodities; presorted=ps)
    new_count = min(ffd_count, bfd_count)
    current_count = a.bins_dirty ? ffd_count : length(a.bins)
    if !a.bins_dirty && new_count >= current_count
        return 0.0
    end

    before = a.cost
    a.bins = if ffd_count <= bfd_count
        compute_bin_assignments(arc.cost, a.commodities; presorted=ps)
    else
        compute_bin_assignments_bfd(arc.cost, a.commodities; presorted=ps)
    end
    a.cost = arc.cost.cost_per_bin * length(a.bins)
    a.bins_dirty = false
    return before - a.cost
end

function _repack_assignment!(a::MultiAssignment, arc::MultiModalArc)
    saved = 0.0
    for (i, slot) in enumerate(a.per_mode)
        mode_cost = arc.modes[i].cost
        mode_cost isa BinPackingArcCost || continue
        ps = slot.sorted
        ffd_count = tentative_bin_count(mode_cost, slot.commodities; presorted=ps)
        bfd_count = tentative_best_fit_count(mode_cost, slot.commodities; presorted=ps)
        new_count = min(ffd_count, bfd_count)
        current_count = slot.bins_dirty ? ffd_count : length(slot.bins)
        if !slot.bins_dirty && new_count >= current_count
            continue
        end

        before = slot.cost
        slot.bins = if ffd_count <= bfd_count
            compute_bin_assignments(mode_cost, slot.commodities; presorted=ps)
        else
            compute_bin_assignments_bfd(mode_cost, slot.commodities; presorted=ps)
        end
        slot.cost = mode_cost.cost_per_bin * length(slot.bins)
        slot.bins_dirty = false
        saved += before - slot.cost
    end
    return saved
end

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

# --- Pre-allocated Dijkstra workspace (avoids per-call array allocation) ---

struct DijkstraWorkspace
    dists::Vector{Float64}
    parents::Vector{Int}
end

function DijkstraWorkspace(n::Int)
    return DijkstraWorkspace(Vector{Float64}(undef, n), Vector{Int}(undef, n))
end

function _reset_workspace!(ws::DijkstraWorkspace, origin::Int)
    fill!(ws.dists, Inf)
    fill!(ws.parents, 0)
    ws.dists[origin] = 0.0
    return ws
end

# --- Snapshot helpers for assignment state (used by _try_reinsert_bundle!) ---

struct _SingleAssignmentSnapshot{C<:LightCommodity}
    commodities::Vector{C}
    bins::Vector{Bin{C}}
    cost::Float64
    sorted::Bool
    total_size::Float64
    bins_dirty::Bool
end

function _snapshot_assignment(a::SingleAssignment{C}) where {C}
    return _SingleAssignmentSnapshot{C}(
        copy(a.commodities), a.bins, a.cost, a.sorted, a.total_size, a.bins_dirty
    )
end

function _restore_assignment!(a::SingleAssignment, snap::_SingleAssignmentSnapshot)
    a.commodities = snap.commodities
    a.bins = snap.bins
    a.cost = snap.cost
    a.sorted = snap.sorted
    a.total_size = snap.total_size
    a.bins_dirty = snap.bins_dirty
    return nothing
end

struct _MultiAssignmentSnapshot{C<:LightCommodity}
    per_mode::Vector{_SingleAssignmentSnapshot{C}}
end

function _snapshot_assignment(a::MultiAssignment{C}) where {C}
    return _MultiAssignmentSnapshot{C}([_snapshot_assignment(slot) for slot in a.per_mode])
end

function _restore_assignment!(a::MultiAssignment, snap::_MultiAssignmentSnapshot)
    for (slot, slot_snap) in zip(a.per_mode, snap.per_mode)
        _restore_assignment!(slot, slot_snap)
    end
    return nothing
end

const _SnapshotUnion{C} = Union{_SingleAssignmentSnapshot{C},_MultiAssignmentSnapshot{C}}

function _snapshot_path_assignments(
    sol::Solution{C},
    instance::Instance,
    bundle_idx::Int;
    cache::Union{Dict{Tuple{Int,Int},_SnapshotUnion{C}},Nothing}=nothing,
) where {C}
    path = sol.bundle_paths[bundle_idx]
    bundle = instance.bundles[bundle_idx]
    snapshots = if cache !== nothing
        empty!(cache)
        cache
    else
        Dict{Tuple{Int,Int},_SnapshotUnion{C}}()
    end
    for order in bundle.orders
        for k in 1:(length(path) - 1)
            u_tsg = project_to_time_space_graph(path[k], order, instance)
            v_tsg = project_to_time_space_graph(path[k + 1], order, instance)
            edge = (u_tsg, v_tsg)
            haskey(snapshots, edge) && continue
            haskey(sol.assignments, edge) || continue
            snapshots[edge] = _snapshot_assignment(sol.assignments[edge])
        end
    end
    return snapshots
end

function _restore_path_assignments!(
    sol::Solution, bundle_idx::Int, old_path::Vector{Int}, snapshots::Dict
)
    sol.bundle_paths[bundle_idx] = old_path
    for (edge, snap) in snapshots
        _restore_assignment!(sol.assignments[edge], snap)
    end
    return nothing
end

function _snapshot_multi_bundle_assignments(
    sol::Solution{C}, instance::Instance, bundle_idxs::Vector{Int}
) where {C}
    snapshots = Dict{Tuple{Int,Int},_SnapshotUnion{C}}()
    for bi in bundle_idxs
        path = sol.bundle_paths[bi]
        bundle = instance.bundles[bi]
        for order in bundle.orders
            for k in 1:(length(path) - 1)
                u_tsg = project_to_time_space_graph(path[k], order, instance)
                v_tsg = project_to_time_space_graph(path[k + 1], order, instance)
                edge = (u_tsg, v_tsg)
                haskey(snapshots, edge) && continue
                haskey(sol.assignments, edge) || continue
                snapshots[edge] = _snapshot_assignment(sol.assignments[edge])
            end
        end
    end
    return snapshots
end

function _refresh_dirty_assignments!(sol::Solution, instance::Instance, edges)
    cache = instance.index_cache
    for edge in edges
        assignment = get(sol.assignments, edge, nothing)
        assignment === nothing && continue
        su = cache.tsg_code_to_spatial_code[edge[1]]
        sv = cache.tsg_code_to_spatial_code[edge[2]]
        arc = cache.spatial_pair_to_arc[(su, sv)]
        if assignment isa SingleAssignment
            assignment.bins_dirty || continue
            _update_single_assignment_cost!(assignment, arc.cost)
        else
            for (i, slot) in enumerate(assignment.per_mode)
                slot.bins_dirty || continue
                _update_single_assignment_cost!(slot, arc.modes[i].cost)
            end
        end
    end
    return nothing
end

function _restore_multi_bundle_assignments!(
    sol::Solution, bundle_idxs::Vector{Int}, old_paths::Vector{Vector{Int}}, snapshots::Dict
)
    for (k, bi) in enumerate(bundle_idxs)
        sol.bundle_paths[bi] = old_paths[k]
    end
    for (edge, snap) in snapshots
        _restore_assignment!(sol.assignments[edge], snap)
    end
    return nothing
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

Random-neighborhood local search driver mirroring STP's `local_search!`. Each
iteration flips a fair coin to pick one move:

- Bundle reintroduction: a random bundle index is selected, its current path
  is removed, the cost matrix is recomputed against the now-bundle-less
  solution, and a Dijkstra-found new path is accepted iff it strictly improves
  the total cost. Implemented by `_try_reinsert_bundle!`.
- Two-node consolidation: a random `(src, dst)` pair is selected from the set
  of valid `:other -> :other / :destination` arcs in the TTG. Every bundle
  whose current path traverses `(src, dst)` is lifted, a merged virtual bundle
  is rerouted between the two nodes via Dijkstra, and each lifted bundle's
  sub-path is spliced through the new segment. Accepted iff the total cost
  strictly improves. Implemented by `two_node_common_incremental!`.

The loop exits when any of three conditions hits: `time_limit` seconds elapsed,
`max_iter` iterations attempted, or `max_no_improv` consecutive iterations
without improvement (improvement below `1.0`, matching STP's tolerance).

After the loop a single `bin_packing_improvement!` pass is run when
`allow_repack=true`. It is not interleaved per iteration because most
iterations modify zero or very few arcs (a global pass at the end captures the
same opportunities at lower amortized cost).

Per-move pre-filtering: `cost_threshold_relative * start_cost` is passed as the
`cost_threshold` to both move types, so candidates whose estimated removal cost
is below that threshold are skipped without running Dijkstra.

Set `allow_reintro=false` or `allow_consolidate=false` to disable one move type
(useful for ablation studies). Setting both to false skips straight to the
final repack.

`refine_two_node` controls whether lifted bundles are individually re-inserted
after a two-node splice (defaults to `false`, matching STP). Setting it to
`true` can improve per-move quality at the cost of 4-9x slower two-node moves.

The `packing` keyword defaults to `:ffd_union` and controls the commit
operations (remove/add path). The `cost_packing` keyword defaults to
`:frozen` and controls the cost matrix estimation for Dijkstra. Frozen
packing is cheaper (O(n_new) vs O(n_existing + n_new)) and a good estimate.

Returns a [`LocalSearchResult`](@ref) with diagnostic info (cost improvement,
iteration counts, and time-series samples for plotting convergence curves).
"""
function local_search!(
    sol::Solution{C},
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    time_limit::Real=60.0,
    max_iter::Int=500_000,
    max_no_improv::Int=15_000,
    cost_threshold_relative::Real=5e-5,
    allow_reintro::Bool=true,
    allow_consolidate::Bool=true,
    allow_repack::Bool=true,
    refine_two_node::Bool=false,
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
    rng::Random.AbstractRNG=Random.default_rng(),
    sample_every::Int=1000,
) where {C}
    t_start = time()
    start_cost = cost(sol)
    cost_threshold = cost_threshold_relative * start_cost

    ttg = instance.travel_time_graph
    src_codes, dst_codes = compute_candidate_nodes(ttg)
    valid_pairs = Tuple{Int,Int}[]
    for s in src_codes, d in dst_codes
        s != d && Graphs.has_edge(ttg.graph, s, d) && push!(valid_pairs, (s, d))
    end
    can_consolidate = allow_consolidate && !isempty(valid_pairs)
    can_reintro = allow_reintro && !isempty(instance.bundles)

    tot_improv = 0.0
    no_improv = 0
    iter = 0
    timestamps = Float64[0.0]
    costs = Float64[start_cost]
    iters_at_sample = Int[0]

    n_bundles = length(instance.bundles)
    shared_buffer = BinPackingBuffer()
    # Pre-compute per-bundle adjacency lists from bundle_arcs. These are
    # static (independent of the solution) and reused across all lazy
    # Dijkstra calls to avoid per-reinsertion Dict construction.
    bundle_adjs = Vector{Dict{Int,Vector{Int}}}(undef, n_bundles)
    n_ttg_nodes = Graphs.nv(ttg.graph)
    workspace = DijkstraWorkspace(n_ttg_nodes)

    # Thread-local buffer pool for parallel cost matrix computation.
    # One BinPackingBuffer per thread, indexed by threadid().
    buffer_pool = if Threads.nthreads() > 1
        create_buffer_pool()
    else
        nothing
    end

    # Pre-allocated snapshot Dict, reused across iterations via empty!.
    snapshot_cache = Dict{Tuple{Int,Int},_SnapshotUnion{C}}()

    if can_reintro
        ttg = instance.travel_time_graph
        for i in 1:n_bundles
            adj = Dict{Int,Vector{Int}}()
            for (u, v) in ttg.bundle_arcs[i]
                push!(get!(adj, u, Int[]), v)
            end
            bundle_adjs[i] = adj
        end
    end

    if can_reintro || can_consolidate
        while (time() - t_start < time_limit) &&
                  (iter < max_iter) &&
                  (no_improv < max_no_improv)
            take_reintro = if can_reintro && can_consolidate
                rand(rng) < 0.5
            else
                can_reintro
            end

            improved = if take_reintro
                _run_reintro_step!(
                    sol,
                    instance,
                    mode_selector,
                    rng,
                    cost_threshold,
                    packing,
                    cost_packing;
                    buffer=shared_buffer,
                    bundle_adjs,
                    workspace,
                    buffer_pool,
                    snapshot_cache,
                )
            elseif can_consolidate
                _run_two_node_step!(
                    sol,
                    instance,
                    valid_pairs,
                    mode_selector,
                    rng,
                    cost_threshold,
                    refine_two_node,
                    packing,
                    cost_packing;
                    bundle_adjs,
                    buffer=shared_buffer,
                    workspace,
                    buffer_pool,
                    snapshot_cache,
                )
            else
                0.0
            end

            tot_improv += improved
            if improved < 1.0
                no_improv += 1
            else
                no_improv = 0
            end
            iter += 1
            if iter % sample_every == 0
                push!(timestamps, time() - t_start)
                push!(costs, start_cost - tot_improv)
                push!(iters_at_sample, iter)
            end
        end
    end

    if allow_repack
        tot_improv += bin_packing_improvement!(sol, instance)
    end
    push!(timestamps, time() - t_start)
    push!(costs, start_cost - tot_improv)
    push!(iters_at_sample, iter)

    return LocalSearchResult(
        tot_improv,
        start_cost - tot_improv,
        iter,
        no_improv,
        timestamps,
        costs,
        iters_at_sample,
    )
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

function _rebuild_reintro_candidates!(candidates::Vector{Int}, sol::Solution)
    empty!(candidates)
    for i in eachindex(sol.bundle_paths)
        isempty(sol.bundle_paths[i]) || push!(candidates, i)
    end
    return candidates
end

"""
$TYPEDSIGNATURES

Pre-compute a mapping from each spatial arc `(su, sv)` to the bundle indices
whose reachable TTG arcs project to that spatial arc. This is a static
property of the instance (independent of the current solution) and enables
targeted dirty-marking after a successful LS move: instead of re-evaluating
all bundles, only those sharing an affected spatial arc are re-added to the
candidate set.
"""
function _build_spatial_to_bundles(instance::Instance)
    cache = instance.index_cache
    ttg = instance.travel_time_graph
    spatial_to_bundles = Dict{Tuple{Int,Int},Vector{Int}}()
    for (bi, arcs) in enumerate(ttg.bundle_arcs)
        seen = Set{Tuple{Int,Int}}()
        for (u, v) in arcs
            su = cache.ttg_code_to_spatial_code[u]
            sv = cache.ttg_code_to_spatial_code[v]
            su == sv && continue
            key = (su, sv)
            key in seen && continue
            push!(seen, key)
            if !haskey(spatial_to_bundles, key)
                spatial_to_bundles[key] = Int[]
            end
            push!(spatial_to_bundles[key], bi)
        end
    end
    return spatial_to_bundles
end

"""
$TYPEDSIGNATURES

After a successful reinsertion of `moved_bundle`, mark the bundles that share
spatial arcs with the old or new path as dirty (needing re-evaluation). Only
clean bundles are affected: dirty bundles are already in the candidate set.
"""
function _mark_dirty_after_move!(
    candidates::Vector{Int},
    in_candidates::BitVector,
    clean::BitVector,
    old_path::Vector{Int},
    new_path::Vector{Int},
    cache,
    sol::Solution,
    spatial_to_bundles::Dict{Tuple{Int,Int},Vector{Int}},
    moved_bundle::Int,
)
    for path in (old_path, new_path)
        for i in 1:(length(path) - 1)
            su = cache.ttg_code_to_spatial_code[path[i]]
            sv = cache.ttg_code_to_spatial_code[path[i + 1]]
            su == sv && continue
            for bi in get(spatial_to_bundles, (su, sv), Int[])
                if clean[bi]
                    clean[bi] = false
                    if !in_candidates[bi] && !isempty(sol.bundle_paths[bi])
                        push!(candidates, bi)
                        in_candidates[bi] = true
                    end
                end
            end
        end
    end
    clean[moved_bundle] = false
    if !in_candidates[moved_bundle] && !isempty(sol.bundle_paths[moved_bundle])
        push!(candidates, moved_bundle)
        in_candidates[moved_bundle] = true
    end
    return nothing
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

"""
$TYPEDSIGNATURES

Candidate-set variant of `_run_reintro_step!` with arc-level dirty tracking.
Picks a random bundle from `candidates`, runs `_try_reinsert_bundle!`, and
removes the bundle from `candidates` when Dijkstra returns the same path (no
better route exists under the current assignment state). Bundles with empty
paths or below the cost threshold are also removed.

When a move succeeds, only bundles sharing spatial arcs with the moved
bundle's old/new paths are re-added to `candidates` (targeted dirty marking).
This avoids the full candidate rebuild that would otherwise re-evaluate every
bundle after each improvement.
"""
function _run_reintro_step_from_candidates!(
    sol::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector,
    rng::Random.AbstractRNG,
    cost_threshold::Float64,
    packing::Symbol,
    cost_packing::Symbol,
    candidates::Vector{Int},
    in_candidates::BitVector,
    clean::BitVector,
    spatial_to_bundles::Dict{Tuple{Int,Int},Vector{Int}},
    buffer::BinPackingBuffer,
    bundle_adjs::Vector{Dict{Int,Vector{Int}}},
)
    isempty(candidates) && return 0.0
    idx = rand(rng, 1:length(candidates))
    bundle_idx = candidates[idx]

    if isempty(sol.bundle_paths[bundle_idx])
        _swap_remove!(candidates, in_candidates, idx)
        return 0.0
    end
    if cost_threshold > 0 &&
        bundle_estimated_removal_cost(sol, instance, bundle_idx) <= cost_threshold
        return 0.0
    end

    # Keep a reference to the current path vector. _try_reinsert_bundle!
    # replaces it only when Dijkstra finds a different path (accepted or
    # rejected-then-rolled-back via copy). Same-path returns leave the
    # reference unchanged, so identity comparison detects that case.
    # On success, path_ref still holds the original (old) path contents.
    path_ref = sol.bundle_paths[bundle_idx]
    improved = _try_reinsert_bundle!(
        sol,
        instance,
        bundle_idx,
        mode_selector;
        packing,
        cost_packing,
        buffer,
        bundle_adj=bundle_adjs[bundle_idx],
    )
    if improved < 1.0 && sol.bundle_paths[bundle_idx] === path_ref
        _swap_remove!(candidates, in_candidates, idx)
        clean[bundle_idx] = true
    elseif improved >= 1.0
        _mark_dirty_after_move!(
            candidates,
            in_candidates,
            clean,
            path_ref,
            sol.bundle_paths[bundle_idx],
            instance.index_cache,
            sol,
            spatial_to_bundles,
            bundle_idx,
        )
    end
    return improved
end

function _swap_remove!(v::Vector{Int}, in_v::BitVector, idx::Int)
    old = v[idx]
    v[idx] = v[end]
    pop!(v)
    in_v[old] = false
    return v
end

"""
$TYPEDSIGNATURES

One two-node consolidation step: pick a random `(src, dst)` pair from
`valid_pairs` and delegate to `two_node_common_incremental!`. The `refine`
argument forwards to that move (when true, lifted bundles are individually
re-inserted after the splice). Returns the per-step cost improvement (`0.0`
if no bundles traversed the arc or the move was rejected).
"""
function _run_two_node_step!(
    sol::Solution,
    instance::Instance,
    valid_pairs::Vector{Tuple{Int,Int}},
    mode_selector::AbstractModeSelector,
    rng::Random.AbstractRNG,
    cost_threshold::Float64,
    refine::Bool,
    packing::Symbol,
    cost_packing::Symbol;
    bundle_adjs::Union{Vector{Dict{Int,Vector{Int}}},Nothing}=nothing,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
    buffer_pool::Union{Vector{<:BinPackingBuffer},Nothing}=nothing,
    snapshot_cache::Union{Dict,Nothing}=nothing,
)
    isempty(valid_pairs) && return 0.0
    (src, dst) = rand(rng, valid_pairs)
    return two_node_common_incremental!(
        sol,
        instance,
        src,
        dst;
        mode_selector,
        cost_threshold,
        refine,
        packing,
        cost_packing,
        bundle_adjs,
        buffer,
        workspace,
        buffer_pool,
        snapshot_cache,
    )
end
