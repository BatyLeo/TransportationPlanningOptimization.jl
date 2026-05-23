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
    current_count = length(a.bins)
    ffd_count = tentative_bin_count(arc.cost, a.commodities)
    bfd_count = tentative_best_fit_count(arc.cost, a.commodities)
    new_count = min(ffd_count, bfd_count)
    new_count >= current_count && return 0.0  # gate: no improvement possible

    before = a.cost
    a.bins = if ffd_count <= bfd_count
        compute_bin_assignments(arc.cost, a.commodities)
    else
        compute_bin_assignments_bfd(arc.cost, a.commodities)
    end
    a.cost = arc.cost.cost_per_bin * length(a.bins)
    return before - a.cost
end

function _repack_assignment!(a::MultiAssignment, arc::MultiModalArc)
    saved = 0.0
    for (i, slot) in enumerate(a.per_mode)
        mode_cost = arc.modes[i].cost
        mode_cost isa BinPackingArcCost || continue
        current_count = length(slot.bins)
        ffd_count = tentative_bin_count(mode_cost, slot.commodities)
        bfd_count = tentative_best_fit_count(mode_cost, slot.commodities)
        new_count = min(ffd_count, bfd_count)
        new_count >= current_count && continue

        before = slot.cost
        slot.bins = if ffd_count <= bfd_count
            compute_bin_assignments(mode_cost, slot.commodities)
        else
            compute_bin_assignments_bfd(mode_cost, slot.commodities)
        end
        slot.cost = mode_cost.cost_per_bin * length(slot.bins)
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
)
    saved = 0.0
    t_start = time()
    ttg = instance.travel_time_graph
    for i in eachindex(instance.bundles)
        time() - t_start > time_limit && break
        isempty(sol.bundle_paths[i]) && continue
        if cost_threshold > 0 &&
            bundle_estimated_removal_cost(sol, instance, i) <= cost_threshold
            continue
        end

        old_path = copy(sol.bundle_paths[i])
        cost_removed = remove_bundle_path!(sol, instance, i)  # <= 0
        update_bundle_cost_matrix!(sol, instance, i, mode_selector)
        origin = ttg.origin_codes[i]
        dest = ttg.destination_codes[i]
        res = Graphs.dijkstra_shortest_paths(ttg.graph, origin, ttg.cost_matrix)
        new_path = Graphs.enumerate_paths(res, dest)

        if isempty(new_path)
            add_bundle_path!(sol, instance, i, old_path; mode_selector)
            continue
        end

        cost_added = add_bundle_path!(sol, instance, i, new_path; mode_selector)
        net_delta = cost_added + cost_removed  # negative if improvement
        if net_delta < -1e-6
            saved += -net_delta
        else
            remove_bundle_path!(sol, instance, i)
            add_bundle_path!(sol, instance, i, old_path; mode_selector)
        end
    end
    return saved
end

"""
$TYPEDSIGNATURES

Drive a basic local search: alternate `bundle_reinsertion_improvement!` and
`bin_packing_improvement!` (in that order) until total improvement in a
sweep drops below `relative_tolerance * start_cost`, or the wall-time budget
`time_limit` is exhausted. Returns `sol` for chaining.

The `relative_tolerance` defaults to `5e-5`, matching the corresponding
parameter in the Renault reference implementation. Likewise,
`cost_threshold_relative` (default `5e-5`) is scaled by `start_cost` and
passed to `bundle_reinsertion_improvement!` to skip bundles with negligible
cost contribution.

Order rationale: reinsertion may leave bin packings sub-optimal on the
affected arcs (the cost delta is computed via the same FFD heuristic used
on insertion, but a different ordering can occasionally open BFD
improvements). Running `bin_packing_improvement!` after reinsertion gives it
a chance to find those reductions in the same sweep.
"""
function local_search!(
    sol::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    time_limit::Real=60.0,
    relative_tolerance::Real=5e-5,
    cost_threshold_relative::Real=5e-5,
)
    t_start = time()
    start_cost = cost(sol)
    tolerance = max(1.0, relative_tolerance * start_cost)
    cost_threshold = cost_threshold_relative * start_cost
    while time() - t_start < time_limit
        improved = bundle_reinsertion_improvement!(
            sol,
            instance,
            mode_selector;
            time_limit=max(0, time_limit - (time() - t_start)),
            cost_threshold,
        )
        improved += bin_packing_improvement!(sol, instance)
        improved < tolerance && break
    end
    return sol
end
