"""
$TYPEDEF

A linear cost function where the cost is directly proportional to the total size/load on the arc.

# Fields
$TYPEDFIELDS
"""
struct LinearArcCost <: AbstractArcCostFunction
    "Unit cost per unit of size"
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
