# ideally, non decreasing with size
"""
$TYPEDEF

Abstract base type for cost functions defined on network arcs.
Concrete subtypes determine how load/size on an arc is translated into a financial or performance cost.
"""
abstract type AbstractArcCostFunction end

"""
$TYPEDEF

Abstract supertype for arcs in the spatial network graph.

Concrete subtypes:
- `NetworkArc` (single transport mode, the common case)
- `MultiModalArc` (a leg traversable by several transport modes, e.g., truck and train sharing the same physical leg)

Methods that need to act on either form should dispatch on this supertype.
"""
abstract type AbstractNetworkArc end

"""
$TYPEDEF

A linear cost function where the cost is directly proportional to the total size/load on the arc.

# Fields
$TYPEDFIELDS
"""
struct LinearArcCost <: AbstractArcCostFunction
    "Unit cost per unit of size (e.g. m³, kg, etc.)"
    cost_per_unit_size::Float64
end

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
# algebraic data types
# multi criteria
struct VectorPackingArcCost <: AbstractArcCostFunction end

# grid: discretized km, m3, kg -> cost per m3
struct GridLinearArcCost <: AbstractArcCostFunction end

# cout arc de douane (qui passe par un point de douane)

"""
A small marker cost function used to represent shortcut / wait arcs.
This makes dispatch and checks explicit instead of relying on numeric values.
"""
struct ShortcutArcCost <: AbstractArcCostFunction end

"""
$TYPEDSIGNATURES

Evaluate the cost of transporting a list of commodities on an arc with a linear cost function.
The cost is proportional to the total size of all commodities.
"""
function evaluate(
    arc_f::LinearArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    total_size = sum(c.size for c in commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_size
end

"""
$TYPEDSIGNATURES

Evaluate the cost of transporting a list of commodities on an arc with a bin-packing cost function.
The cost is based on the number of bins (trucks) needed to transport all commodities.
Uses the First-Fit Decreasing (FFD) heuristic to determine bin assignments and count.
"""
function evaluate(
    arc_f::BinPackingArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    # tentative_bin_count returns the same `length` as compute_bin_assignments
    # without allocating Bin objects, and honors the presorted hint.
    return arc_f.cost_per_bin * tentative_bin_count(arc_f, commodities; presorted)
end

"""
$TYPEDSIGNATURES

Evaluate the cost of a shortcut (wait) arc: always zero.
"""
evaluate(::ShortcutArcCost, ::Vector{<:LightCommodity}; presorted::Bool=false) = 0.0

"""
$TYPEDSIGNATURES

Fallback for cost function types that have not yet implemented `evaluate`.
Throws to prevent silently incorrect (zero) costs during development.
"""
function evaluate(
    arc_f::AbstractArcCostFunction, ::Vector{<:LightCommodity}; presorted::Bool=false
)
    return throw(
        ArgumentError("evaluate not implemented for cost function of type $(typeof(arc_f))")
    )
end
