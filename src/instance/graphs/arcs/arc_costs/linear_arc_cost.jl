"""
$TYPEDEF

A linear cost function where the cost is directly proportional to the total size/load on the arc.

# Fields
$TYPEDFIELDS
"""
struct LinearArcCost <: AbstractArcCostFunction
    "unit cost per unit of size"
    cost_per_unit_size::Float64
end

"""
$TYPEDSIGNATURES

Evaluate the cost of transporting a list of commodities on an arc with a linear cost
function. The cost is proportional to the total size of all commodities.
"""
function evaluate(
    arc_f::LinearArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    total_size = sum(c.size for c in commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_size
end

"""
$TYPEDSIGNATURES

O(1) incremental cost from a precomputed total size.
"""
function incremental_cost_with_size(
    arc_f::LinearArcCost, ::Vector{C}, ::Vector{C}, new_total_size::Float64
) where {C<:LightCommodity}
    return arc_f.cost_per_unit_size * new_total_size
end

"""
$TYPEDSIGNATURES

Linear cost is additive, so the marginal cost depends only on `new`.
"""
function incremental_cost(
    arc_f::LinearArcCost, existing::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    new_total_size = sum(c.size for c in new_commodities; init=0.0)
    return incremental_cost_with_size(arc_f, existing, new_commodities, new_total_size)
end
