"""
$TYPEDSIGNATURES

Update the per-arc cost scaling factors in `instance.travel_time_graph.cost_scaling`
based on the bin utilization of `sol`.

For each solution edge backed by a `BinPackingArcCost` (directly, or as a term inside a
`SumArcCost`), the scaling factor is `n_bins / n_bins_continuous`, where
`n_bins_continuous = ceil(total_volume / bin_capacity)` is the number of bins the
continuous (fractional) relaxation would need. A factor above `1.0` means the arc is
under-utilized relative to the continuous relaxation (more bins are open than the volume
strictly requires) and should be discouraged; a factor below `1.0` means it is well packed
and should be encouraged. The factor is clamped to `(0.0, 2.0]`.

Edges with no volume, no bin-packing cost component, or a factor of exactly `1.0` (a no-op)
are left out of the dict, keeping `cost_matrix_update`'s hot-path lookup cheap.
`instance.travel_time_graph.cost_scaling` is cleared before being repopulated, so calling
this on an empty `sol` leaves it empty.

Multi-modal edges (`MultiAssignment`) are skipped: `cost_scaling` is keyed per spatial arc,
not per mode, so a single scaling factor cannot represent modes with distinct bin
capacities. Left as a future extension.

This is the slope scaling callback for [`iterated_local_search!`](@ref).
Pass as `cost_update! = slope_scaling_update!`.
"""
function slope_scaling_update!(instance::Instance, sol::Solution)
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
    su = cache.tsg_spatial[u_tsg]
    sv = cache.tsg_spatial[v_tsg]
    arc = get(cache.arc_of, (su, sv), nothing)
    arc === nothing && return nothing

    bp_cost = _bin_packing_cost_of(arc.cost)
    bp_cost === nothing && return nothing

    total_volume = total_size_of(assignment)
    total_volume <= 0 && return nothing

    n_bins_continuous = ceil(Int, total_volume / bp_cost.bin_capacity)
    n_bins_continuous <= 0 && return nothing

    n_bins = if assignment.bins_dirty
        tentative_bin_count(bp_cost, assignment.commodities; presorted=assignment.sorted)
    else
        length(assignment.bins)
    end
    n_bins == 0 && return nothing

    factor = clamp(n_bins / n_bins_continuous, 0.0, 2.0)
    isapprox(factor, 1.0; atol=1e-9) && return nothing

    ttg.cost_scaling[(su, sv)] = factor
    return nothing
end

function _slope_scaling_update_edge!(
    ::TravelTimeGraph, ::IndexCache, ::Int, ::Int, ::MultiAssignment
)
    return nothing
end

"""
$TYPEDSIGNATURES

Return the `BinPackingArcCost` backing `cost`, or `nothing` if `cost` has no
bin-packing component (a bare non-bin-packing cost, or a `SumArcCost` without a
`BinPackingArcCost` term).
"""
_bin_packing_cost_of(cost::BinPackingArcCost) = cost
_bin_packing_cost_of(cost::SumArcCost) = _find_bin_packing(cost)
_bin_packing_cost_of(::AbstractArcCostFunction) = nothing
