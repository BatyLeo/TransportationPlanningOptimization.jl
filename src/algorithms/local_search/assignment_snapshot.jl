# Snapshot / restore machinery for assignment state. Local-search moves
# tentatively mutate the assignments along a bundle's path, then either keep
# the change (when it improves cost) or roll back to the snapshot. Used by
# `_try_reinsert_bundle!` and `two_node_common_incremental!`.
#
# A move snapshots every edge it can touch (the edges of the old and of the new
# paths), including edges that do not exist yet (stored as `nothing`, restoring
# them deletes the edge). Rolling back is then restore-only. Snapshots are used
# once: they deep-copy the bins, and restoring hands the copies to the solution.

struct _SingleAssignmentSnapshot{C<:LightCommodity}
    commodities::Vector{C}
    bins::Vector{Bin{C}}
    arc_cost::Float64
    node_cost::Float64
    sorted::Bool
    total_size::Float64
end

function _snapshot_assignment(a::SingleAssignment{C}) where {C}
    return _SingleAssignmentSnapshot{C}(
        copy(a.commodities),
        [Bin(copy(b.commodities), b.remaining_capacity) for b in a.bins],
        a.arc_cost,
        a.node_cost,
        a.sorted,
        a.total_size,
    )
end

function _restore_assignment!(a::SingleAssignment, snap::_SingleAssignmentSnapshot)
    a.commodities = snap.commodities
    a.bins = snap.bins
    a.arc_cost = snap.arc_cost
    a.node_cost = snap.node_cost
    a.sorted = snap.sorted
    a.total_size = snap.total_size
    return nothing
end

struct _MultiAssignmentSnapshot{C<:LightCommodity}
    per_mode::Vector{_SingleAssignmentSnapshot{C}}
    node_cost::Float64
end

function _snapshot_assignment(a::MultiAssignment{C}) where {C}
    return _MultiAssignmentSnapshot{C}(
        [_snapshot_assignment(slot) for slot in a.per_mode], a.node_cost
    )
end

function _restore_assignment!(a::MultiAssignment, snap::_MultiAssignmentSnapshot)
    for (slot, slot_snap) in zip(a.per_mode, snap.per_mode)
        _restore_assignment!(slot, slot_snap)
    end
    a.node_cost = snap.node_cost
    return nothing
end

# `nothing` marks an edge that had no assignment when the snapshot was taken.
const _SnapshotUnion{C} = Union{
    _SingleAssignmentSnapshot{C},_MultiAssignmentSnapshot{C},Nothing
}

"""
$TYPEDSIGNATURES

Snapshot the assignments of the edges of `path` for `bundle_idx` into `cache` (a fresh
dictionary when `nothing`, emptied first when `clear`). Edges already in the dictionary are
kept, so the earliest state wins. Edges without an assignment are stored as `nothing`.
"""
function _snapshot_path_assignments(
    sol::SolutionState{C},
    instance::Instance,
    bundle_idx::Int,
    path::Vector{Int};
    cache::Union{Dict{Tuple{Int,Int},_SnapshotUnion{C}},Nothing}=nothing,
    clear::Bool=true,
) where {C}
    bundle = instance.bundles[bundle_idx]
    snapshots = if cache !== nothing
        clear && empty!(cache)
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
            assignment = get(sol.assignments, edge, nothing)
            snapshots[edge] =
                assignment === nothing ? nothing : _snapshot_assignment(assignment)
        end
    end
    return snapshots
end

"""
$TYPEDSIGNATURES

Restore `snapshots` and set the path of `bundle_idx` back to `old_path`.
"""
function _restore_path_assignments!(
    sol::SolutionState, bundle_idx::Int, old_path::Vector{Int}, snapshots::Dict
)
    sol.bundle_paths[bundle_idx] = old_path
    _restore_snapshots!(sol, snapshots)
    return nothing
end

function _restore_snapshots!(sol::SolutionState, snapshots::Dict)
    for (edge, snap) in snapshots
        if snap === nothing
            delete!(sol.assignments, edge)
        else
            _restore_assignment!(sol.assignments[edge], snap)
        end
    end
    return nothing
end

function _snapshot_multi_bundle_assignments(
    sol::SolutionState{C}, instance::Instance, bundle_idxs::Vector{Int}
) where {C}
    snapshots = Dict{Tuple{Int,Int},_SnapshotUnion{C}}()
    for bi in bundle_idxs
        _snapshot_path_assignments(
            sol, instance, bi, sol.bundle_paths[bi]; cache=snapshots, clear=false
        )
    end
    return snapshots
end

function _restore_multi_bundle_assignments!(
    sol::SolutionState,
    bundle_idxs::Vector{Int},
    old_paths::Vector{Vector{Int}},
    snapshots::Dict,
)
    for (k, bi) in enumerate(bundle_idxs)
        sol.bundle_paths[bi] = old_paths[k]
    end
    _restore_snapshots!(sol, snapshots)
    return nothing
end
