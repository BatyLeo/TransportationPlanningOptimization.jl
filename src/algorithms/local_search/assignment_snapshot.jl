# Snapshot / restore machinery for assignment state. Local-search moves
# tentatively mutate the assignments along a bundle's path, then either keep
# the change (when it improves cost) or roll back to the snapshot. Used by
# `_try_reinsert_bundle!` and `two_node_common_incremental!`.

struct _SingleAssignmentSnapshot{C<:LightCommodity}
    commodities::Vector{C}
    bins::Vector{Bin{C}}
    arc_cost::Float64
    node_cost::Float64
    sorted::Bool
    total_size::Float64
    bins_dirty::Bool
    dirty_bin_count::Int
end

function _snapshot_assignment(a::SingleAssignment{C}) where {C}
    return _SingleAssignmentSnapshot{C}(
        copy(a.commodities),
        a.bins,
        a.arc_cost,
        a.node_cost,
        a.sorted,
        a.total_size,
        a.bins_dirty,
        a.dirty_bin_count,
    )
end

function _restore_assignment!(a::SingleAssignment, snap::_SingleAssignmentSnapshot)
    a.commodities = snap.commodities
    a.bins = snap.bins
    a.arc_cost = snap.arc_cost
    a.node_cost = snap.node_cost
    a.sorted = snap.sorted
    a.total_size = snap.total_size
    a.bins_dirty = snap.bins_dirty
    a.dirty_bin_count = snap.dirty_bin_count
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

const _SnapshotUnion{C} = Union{_SingleAssignmentSnapshot{C},_MultiAssignmentSnapshot{C}}

function _snapshot_path_assignments(
    sol::Solution{C},
    instance::Instance,
    bundle_idx::Int;
    cache::Union{Dict{Tuple{Int,Int},_SnapshotUnion{C}},Nothing}=nothing,
    clear::Bool=true,
) where {C}
    path = sol.bundle_paths[bundle_idx]
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

Remove bundle `bundle_idx` from `sol` like [`remove_bundle_path!`](@ref), but skip the
edges present in `snapshots`. Meant for rollbacks, where restoring the snapshots
overwrites those slots anyway. The removal deltas are discarded.
"""
function _remove_unsnapshotted_path!(
    sol::Solution, instance::Instance, bundle_idx::Int, snapshots::Dict
)
    path = sol.bundle_paths[bundle_idx]
    isempty(path) && return nothing
    cache = instance.index_cache
    _foreach_path_edge(instance, instance.bundles[bundle_idx], path) do edge, arc, order
        haskey(snapshots, edge) && return 0.0
        _remove_commodities_from_assignment!(
            sol.assignments[edge],
            arc,
            order.commodities,
            cache.spatial_code_to_node_cost,
            cache.tsg_code_to_spatial_code[edge[2]],
        )
        return 0.0
    end
    sol.bundle_paths[bundle_idx] = Int[]
    return nothing
end

"""
$TYPEDSIGNATURES

Roll back a rejected move on `bundle_idx`: remove its current path, skipping the edges
that the snapshot restore overwrites, then restore `old_path` and the snapshots.
"""
function _rollback_bundle!(
    sol::Solution,
    instance::Instance,
    bundle_idx::Int,
    old_path::Vector{Int},
    snapshots::Dict,
)
    _remove_unsnapshotted_path!(sol, instance, bundle_idx, snapshots)
    return _restore_path_assignments!(sol, bundle_idx, old_path, snapshots)
end

function _snapshot_multi_bundle_assignments(
    sol::Solution{C}, instance::Instance, bundle_idxs::Vector{Int}
) where {C}
    snapshots = Dict{Tuple{Int,Int},_SnapshotUnion{C}}()
    for bi in bundle_idxs
        _snapshot_path_assignments(sol, instance, bi; cache=snapshots, clear=false)
    end
    return snapshots
end

function _refresh_dirty_assignments!(sol::Solution, instance::Instance, edges)
    cache = instance.index_cache
    for edge in edges
        assignment = get(sol.assignments, edge, nothing)
        assignment === nothing && continue
        arc = tsg_edge_arc(cache, edge[1], edge[2])
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
