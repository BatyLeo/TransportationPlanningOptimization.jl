"""
$TYPEDSIGNATURES

Repack every `BinPackingArcCost` assignment in `sol` using the better of FFD
and BFD. Only materializes new bins when at least one heuristic strictly
improves on the current bin count. Returns the total cost improvement
(non-negative).
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

function _repack_slot!(slot::SingleAssignment, bp_cost::BinPackingArcCost)
    ps = slot.sorted
    ffd_count = tentative_bin_count(bp_cost, slot.commodities; presorted=ps)
    bfd_count = tentative_best_fit_count(bp_cost, slot.commodities; presorted=ps)
    new_count = min(ffd_count, bfd_count)
    current_count = slot.bins_dirty ? ffd_count : length(slot.bins)
    if !slot.bins_dirty && new_count >= current_count
        return 0.0
    end

    before = slot.cost
    slot.bins = if ffd_count <= bfd_count
        compute_bin_assignments(bp_cost, slot.commodities; presorted=ps)
    else
        compute_bin_assignments_bfd(bp_cost, slot.commodities; presorted=ps)
    end
    slot.cost = bp_cost.cost_per_bin * length(slot.bins)
    slot.bins_dirty = false
    return before - slot.cost
end

function _repack_assignment!(a::SingleAssignment, arc::NetworkArc)
    arc.cost isa BinPackingArcCost || return 0.0
    return _repack_slot!(a, arc.cost)
end

function _repack_assignment!(a::MultiAssignment, arc::MultiModalArc)
    saved = 0.0
    for (i, slot) in enumerate(a.per_mode)
        mode_cost = arc.modes[i].cost
        mode_cost isa BinPackingArcCost || continue
        saved += _repack_slot!(slot, mode_cost)
    end
    return saved
end
