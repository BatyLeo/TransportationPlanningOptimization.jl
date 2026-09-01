# Snapshot / restore machinery for assignment state. Local-search moves
# tentatively mutate the assignments along a bundle's path, then either keep
# the change (when it improves cost) or roll back to the snapshot. Used by
# `_try_reinsert_bundle!` and `two_node_common_incremental!`.

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
