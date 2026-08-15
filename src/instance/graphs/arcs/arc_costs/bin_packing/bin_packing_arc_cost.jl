"""
$TYPEDEF

A bin-packing (or step) cost function. A fixed cost is incurred for each bin/truck needed.
# Fields
$TYPEDFIELDS
"""
struct BinPackingArcCost <: AbstractArcCostFunction
    "Fixed cost for each bin used (e.g., cost per truck)"
    cost_per_bin::Float64
    "Capacity of a single bin/truck"
    bin_capacity::Int
end

"""
$TYPEDSIGNATURES

Evaluate the cost of transporting a list of commodities on an arc with a bin-packing cost
function. The cost is based on the number of bins (trucks) needed to transport all
commodities. Uses the First-Fit Decreasing (FFD) heuristic to determine bin assignments and
count.
"""
function evaluate(
    arc_f::BinPackingArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    return arc_f.cost_per_bin * tentative_bin_count(arc_f, commodities; presorted)
end
