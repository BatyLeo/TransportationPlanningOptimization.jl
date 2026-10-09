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
