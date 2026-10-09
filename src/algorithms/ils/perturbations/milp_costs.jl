"""
$TYPEDSIGNATURES

Linear cost of putting `order` on an arc with cost function `c` in the arc-flow MILP.
It is the lower bound [`lower_bound_incremental_cost_with_order`](@ref) against an empty
arc, which is exact for linear costs and the fractional part for custom costs.
The bins of a [`BinPackingArcCost`](@ref) are not part of it, they are counted by the
integer bin variables of the model (see [`_bin_packing_cost_of`](@ref)).
"""
function _milp_linear_cost(c::AbstractArcCostFunction, order::Order)
    return lower_bound_incremental_cost_with_order(c, nothing, order)
end
_milp_linear_cost(::BinPackingArcCost, ::Order) = 0.0
function _milp_linear_cost(c::SumArcCost, order::Order)
    return sum(_milp_linear_cost(t, order) for t in c.terms)
end
