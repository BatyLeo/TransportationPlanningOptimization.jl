"""
$TYPEDSIGNATURES

Routed bundles of `sol` grouped by `group_by`, with the groups listed in first-seen bundle
order, so a pick among them only depends on the `rng`.
"""
function _routed_groups(sol::SolutionState, instance::Instance, group_by)
    index_of = Dict{Any,Int}()
    groups = Vector{Int}[]
    for (i, bundle) in enumerate(instance.bundles)
        isempty(sol.bundle_paths[i]) && continue
        k = get!(index_of, group_by(bundle), length(groups) + 1)
        k > length(groups) && push!(groups, Int[])
        push!(groups[k], i)
    end
    return groups
end

function _current_cost(sol::SolutionState, edge)
    a = get(sol.assignments, edge, nothing)
    return isnothing(a) ? 0.0 : cost_of(a)
end
_snapshot_cost(::Nothing) = 0.0
_snapshot_cost(s::_SingleAssignmentSnapshot) = s.arc_cost + s.node_cost
function _snapshot_cost(s::_MultiAssignmentSnapshot)
    return sum(slot.arc_cost for slot in s.per_mode; init=0.0) + s.node_cost
end

"""
$TYPEDSIGNATURES

Reroute `bundle_idxs` atomically and accept the result only if it is cheap enough.

The bundles are removed from `sol`, then `reinsert!(sol, instance, snapshots)` must put
them back. Its contract: snapshot the edges of every new path into `snapshots` before
adding the path (for instance through `_try_insert_bundle!(...; snapshots)`) and return
`false` when some bundle cannot be routed. The cost change is computed over the snapshotted
edges only (every edge touched by the old or the new paths), so it does not scan the
whole solution.

The result is kept when `cost_increase <= tolerance * cost_before` and returns
`(cost_increase, n_changed)`, where `n_changed` counts the bundles whose path changed.
An accepted call may have `n_changed == 0` and a nonzero cost increase, when the bundles
keep their paths but their commodities are repacked differently.
Otherwise (including when `reinsert!` returns `false`) the assignments and the bundle
paths are restored exactly and `(0.0, 0)` is returned.
"""
function _reroute_bundles!(
    reinsert!,
    sol::SolutionState,
    instance::Instance,
    bundle_idxs::Vector{Int};
    tolerance::Real,
    cost_before::Real=cost(sol),
)
    old_paths = [copy(sol.bundle_paths[b]) for b in bundle_idxs]
    snapshots = _snapshot_multi_bundle_assignments(sol, instance, bundle_idxs)
    for b in bundle_idxs
        remove_bundle_path!(sol, instance, b)
    end

    ok = reinsert!(sol, instance, snapshots)
    cost_increase = Inf
    if ok
        # Every edge whose assignment changed is a key of `snapshots`.
        cost_increase = sum(
            _current_cost(sol, e) - _snapshot_cost(s) for (e, s) in snapshots; init=0.0
        )
    end

    if ok && cost_increase <= tolerance * cost_before
        n_changed = count(
            sol.bundle_paths[b] != old for (b, old) in zip(bundle_idxs, old_paths)
        )
        return (cost_increase, n_changed)
    end
    _restore_multi_bundle_assignments!(sol, bundle_idxs, old_paths, snapshots)
    return (0.0, 0)
end

"""
$TYPEDSIGNATURES

Snapshot the edges of `path` into `snapshots`, then add it to `sol` as the path of bundle
`bundle_idx`. This is the `reinsert!` step of [`_reroute_bundles!`](@ref) for a given path,
which must not carry shortcut edges at its ends (see `_remove_shortcuts_from_path!`).
"""
function _add_fixed_path!(
    sol::SolutionState, instance::Instance, bundle_idx::Int, path::Vector{Int}, snapshots
)
    _snapshot_path_assignments(
        sol, instance, bundle_idx, path; cache=snapshots, clear=false
    )
    add_bundle_path!(sol, instance, bundle_idx, path)
    return nothing
end

"""
$TYPEDSIGNATURES

Whether every edge in `snapshots` (the edges touched by a reroute) respects the capacity of
its arc, with the same tolerance as [`is_feasible`](@ref).
"""
function _fits_capacities(sol::SolutionState, instance::Instance, snapshots)
    cache = instance.index_cache
    for e in keys(snapshots)
        a = get(sol.assignments, e, nothing)
        isnothing(a) && continue
        arc = tsg_edge_arc(cache, e[1], e[2])
        _capacity_feasible(arc, a, nothing; tol=EPS, verbose=false) || return false
    end
    return true
end
