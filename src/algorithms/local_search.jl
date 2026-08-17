using Random

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

function _snapshot_path_assignments(
    sol::Solution{C}, instance::Instance, bundle_idx::Int
) where {C}
    path = sol.bundle_paths[bundle_idx]
    bundle = instance.bundles[bundle_idx]
    snapshots = Dict{Tuple{Int,Int},Any}()
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

"""
$TYPEDSIGNATURES

Attempt a single-bundle reinsertion. Compute the cost matrix against the
current solution (with the bundle still in place), run Dijkstra, and compare
the new path to the old one. When Dijkstra returns the same path (87-89% of
iterations) or no path, return immediately with no side effects. When a
different path is found, snapshot the bundle's assignment state, remove the
old path, add the new path with full FFD repack, and accept only if the net
cost delta is strictly negative (improvement greater than `1e-6`). Returns
the cost improvement (non-negative `Float64`).

The cost matrix sees the unmodified solution (the bundle's commodities are
still in the assignments). On old-path edges this overestimates the
incremental cost via `frozen_incremental_cost!`, since the bins already
contain the bundle. This is a deliberate trade-off: same-path iterations
(the vast majority) skip snapshot, removal, and restore entirely, while
solution quality is preserved by the exact accept test that uses
`add_bundle_path!` with `:ffd_union` packing.

Used by `bundle_reinsertion_improvement!` as its per-bundle inner step and by
`two_node_common_incremental!` (Phase 3.7) as the refine step. Bundles whose
path is already empty return `0.0` without side effects.

The `packing` keyword defaults to `:ffd_union` for the commit operation
(`add_bundle_path!`) so the accept test is exact. The cost matrix (Dijkstra
edge weights) uses `:frozen` packing by default: it packs new items onto the
existing bins' remaining capacities without re-sorting the union, which is
much cheaper (O(n_new) vs O(n_existing + n_new)) and produces a good-enough
estimate for path selection. The `cost_packing` keyword controls this
independently of the commit packing.
"""
function _try_reinsert_bundle!(
    sol::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector;
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
)
    isempty(sol.bundle_paths[bundle_idx]) && return 0.0
    ttg = instance.travel_time_graph

    old_path = copy(sol.bundle_paths[bundle_idx])

    # Cost matrix update with assignments unmodified. On old-path edges the
    # frozen bins still contain this bundle's commodities, which overestimates
    # the incremental cost there. This is acceptable: the accept test below
    # uses exact costs from add_bundle_path! with :ffd_union packing, so
    # solution quality is preserved. The overestimate only biases Dijkstra's
    # path selection, not the commit decision.
    update_bundle_cost_matrix!(
        sol, instance, bundle_idx, mode_selector; packing=cost_packing
    )
    origin = ttg.origin_codes[bundle_idx]
    dest = ttg.destination_codes[bundle_idx]
    parents, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix)
    new_path = trace_path(parents, origin, dest)

    if isempty(new_path)
        return 0.0
    end

    _remove_shortcuts_from_path!(new_path, ttg)

    if new_path == old_path
        return 0.0
    end

    # Different path found: now snapshot, remove old, and try the new path.
    snapshots = _snapshot_path_assignments(sol, instance, bundle_idx)
    cost_removed = remove_bundle_path!(sol, instance, bundle_idx)
    cost_added = add_bundle_path!(
        sol, instance, bundle_idx, new_path; mode_selector, packing
    )
    net_delta = cost_added + cost_removed
    if net_delta < -1e-6
        return -net_delta
    end

    # Different path, no improvement: rollback via snapshot
    remove_bundle_path!(sol, instance, bundle_idx)
    _restore_path_assignments!(sol, bundle_idx, old_path, snapshots)
    return 0.0
end

"""
$TYPEDSIGNATURES

For each bundle in turn, remove its current path, recompute the cost matrix
against the now-bundle-less solution, run Dijkstra, and accept the new path
only if its net cost delta is strictly negative (improvement greater than
`1e-6`). Otherwise restore the old path. Returns the total cost improvement
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

The `packing` keyword defaults to `:ffd_union` and controls the commit
operations (remove/add path). The `cost_packing` keyword defaults to
`:frozen` and controls the cost matrix estimation for Dijkstra. Frozen
packing is cheaper (O(n_new) vs O(n_existing + n_new)) and a good estimate.

Returns a `NamedTuple` with diagnostic info:

- `saved::Float64`: total cost improvement (accepted moves plus final repack).
- `final_cost::Float64`: `start_cost - saved`.
- `n_iter::Int`: number of iterations performed.
- `n_no_improv::Int`: final no-improvement streak length.
- `timestamps::Vector{Float64}`: wall-time samples from `t_start`, taken every
  `sample_every` iterations plus one at the start and one at the end.
- `costs::Vector{Float64}`: `start_cost - tot_improv` snapshots at the same
  iteration counts.
- `iters_at_sample::Vector{Int}`: iteration counts at each sample.
"""
function local_search!(
    sol::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    time_limit::Real=60.0,
    max_iter::Int=500_000,
    max_no_improv::Int=15_000,
    cost_threshold_relative::Real=5e-5,
    allow_reintro::Bool=true,
    allow_consolidate::Bool=true,
    allow_repack::Bool=true,
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
    rng::Random.AbstractRNG=Random.default_rng(),
    sample_every::Int=1000,
)
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
                    cost_packing,
                )
            else
                _run_two_node_step!(
                    sol,
                    instance,
                    valid_pairs,
                    mode_selector,
                    rng,
                    cost_threshold,
                    allow_reintro,
                    packing,
                    cost_packing,
                )
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

    return (;
        saved=tot_improv,
        final_cost=start_cost - tot_improv,
        n_iter=iter,
        n_no_improv=no_improv,
        timestamps,
        costs,
        iters_at_sample,
    )
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
    cost_packing::Symbol,
)
    n = length(instance.bundles)
    n == 0 && return 0.0
    bundle_idx = rand(rng, 1:n)
    isempty(sol.bundle_paths[bundle_idx]) && return 0.0
    if cost_threshold > 0 &&
        bundle_estimated_removal_cost(sol, instance, bundle_idx) <= cost_threshold
        return 0.0
    end
    return _try_reinsert_bundle!(
        sol, instance, bundle_idx, mode_selector; packing, cost_packing
    )
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
    cost_packing::Symbol,
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
    )
end
