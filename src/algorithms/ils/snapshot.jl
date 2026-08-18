"""
$TYPEDSIGNATURES

Create an independent copy of `sol` that can be restored later via
[`restore_solution!`](@ref). Mutations to `sol` after snapshotting
do not affect the returned copy.
"""
function snapshot_solution(sol::Solution, instance::Instance)
    return deepcopy(sol)
end

"""
$TYPEDSIGNATURES

Restore `sol` to the state captured in `snapshot`. Mutates `sol` in place
and returns it.

After restoration, `sol` is equivalent to `snapshot` at the time it was
taken. The `snapshot` object remains valid and may be reused.
"""
function restore_solution!(sol::Solution, snapshot::Solution, instance::Instance)
    copy!(sol.bundle_paths, snapshot.bundle_paths)
    empty!(sol.assignments)
    merge!(sol.assignments, deepcopy(snapshot.assignments))
    return sol
end
