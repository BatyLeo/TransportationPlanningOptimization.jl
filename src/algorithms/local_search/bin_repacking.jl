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
