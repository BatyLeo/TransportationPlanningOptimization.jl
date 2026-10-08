"""
$TYPEDSIGNATURES

Repack every assignment of `sol` whose cost is or contains a `BinPackingArcCost`
(directly or as a term of a `SumArcCost`) using the better of FFD and BFD.
Only materializes new bins when at least one heuristic strictly improves on the
current bin count.
Returns the total cost improvement (non-negative).
"""
function bin_packing_improvement!(sol::SolutionState, instance::Instance)
    cache = instance.index_cache
    saved = 0.0
    for (edge, assignment) in sol.assignments
        arc = tsg_edge_arc(cache, edge[1], edge[2])
        saved += _repack_assignment!(assignment, arc)
    end
    return saved
end

function _repack_slot!(slot::SingleAssignment, bp_cost::BinPackingArcCost)
    ps = slot.sorted
    ffd_count = tentative_bin_count(bp_cost, slot.commodities; presorted=ps)
    bfd_count = tentative_best_fit_count(bp_cost, slot.commodities; presorted=ps)
    new_count = min(ffd_count, bfd_count)
    current_count = length(slot.bins)
    new_count >= current_count && return 0.0

    before = slot.arc_cost
    slot.bins = if ffd_count <= bfd_count
        compute_bin_assignments(bp_cost, slot.commodities; presorted=ps)
    else
        compute_bin_assignments_bfd(bp_cost, slot.commodities; presorted=ps)
    end
    # Only the bin-packing term depends on the packing, so swap its contribution and keep
    # the other terms of a `SumArcCost`.
    slot.arc_cost =
        before - bp_cost.cost_per_bin * current_count +
        bp_cost.cost_per_bin * length(slot.bins)
    return before - slot.arc_cost
end

function _repack_assignment!(a::SingleAssignment, arc::NetworkArc)
    bp_cost = _bin_packing_cost_of(arc.cost)
    isnothing(bp_cost) && return 0.0
    return _repack_slot!(a, bp_cost)
end

function _repack_assignment!(a::MultiAssignment, arc::MultiModalArc)
    saved = 0.0
    for (i, slot) in enumerate(a.per_mode)
        mode_cost = arc.modes[i].cost
        bp_cost = _bin_packing_cost_of(mode_cost)
        isnothing(bp_cost) && continue
        saved += _repack_slot!(slot, bp_cost)
    end
    return saved
end
