"""
$TYPEDSIGNATURES

Update the edge group cost scaling factors in `instance.travel_time_graph.cost_scaling`
based on the bin utilization of `sol`.
`cost_scaling` is keyed per edge group (spatial pair and transit time), shared by several
time-space edges.

For each solution edge backed by a `BinPackingArcCost` (directly, or as a term inside a
`SumArcCost`), the scaling factor is `n_bins / n_bins_continuous`, where
`n_bins_continuous = ceil(total_volume / bin_capacity)` is the number of bins the
continuous (fractional) relaxation would need. A factor above `1.0` means the edge is
under-utilized relative to the continuous relaxation (more bins are open than the volume
strictly requires), so it is made more expensive. The factor is clamped to `[1.0, 2.0]`
and a group takes the largest factor of its edges.

A group is left out of the dict when none of its edges has a factor other than `1.0`
(no volume, no bin-packing cost component, or a factor of exactly `1.0`).
The factors only enter the objectives of the MILP perturbations. Local search, greedy
insertion and every shortest path search use the true costs.
`instance.travel_time_graph.cost_scaling` is cleared before being repopulated, so calling
this on an empty `sol` leaves it empty.

Multi-modal edges (`MultiAssignment`) are skipped: a single factor per edge group cannot
represent modes with distinct bin capacities. Left as a future extension.

This is the slope scaling callback for [`iterated_local_search!`](@ref), which resets
the factors when it returns.
Pass as `cost_update! = slope_scaling_update!`.
"""
function slope_scaling_update!(instance::Instance, sol::SolutionState)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    empty!(ttg.cost_scaling)

    for ((u_tsg, v_tsg), assignment) in sol.assignments
        _slope_scaling_update_edge!(ttg, cache, u_tsg, v_tsg, assignment)
    end
    return nothing
end

function _slope_scaling_update_edge!(
    ttg::TravelTimeGraph,
    cache::IndexCache,
    u_tsg::Int,
    v_tsg::Int,
    assignment::SingleAssignment,
)
    arc = tsg_edge_arc(cache, u_tsg, v_tsg)
    isnothing(arc) && return nothing

    bp_cost = _bin_packing_cost_of(arc.cost)
    isnothing(bp_cost) && return nothing

    total_volume = total_size_of(assignment)
    total_volume <= 0 && return nothing

    n_bins_continuous = ceil(Int, total_volume / bp_cost.bin_capacity)
    n_bins_continuous <= 0 && return nothing

    n_bins = length(assignment.bins)
    n_bins == 0 && return nothing

    factor = clamp(n_bins / n_bins_continuous, 1.0, 2.0)
    isapprox(factor, 1.0; atol=1e-9) && return nothing

    key = tsg_edge_key(cache, u_tsg, v_tsg)
    ttg.cost_scaling[key] = max(get(ttg.cost_scaling, key, factor), factor)
    return nothing
end

function _slope_scaling_update_edge!(
    ::TravelTimeGraph, ::IndexCache, ::Int, ::Int, ::MultiAssignment
)
    return nothing
end
