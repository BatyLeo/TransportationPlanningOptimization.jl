# network garph should be a multigraph, transformed into a simple graph for time space an travel time graphs
# MixedArcCostFunction

# ideally, non decreasing with size
"""
$TYPEDEF

Abstract base type for cost functions defined on network arcs.
Concrete subtypes determine how load/size on an arc is translated into a financial or performance cost.
"""
abstract type AbstractArcCostFunction end

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
$TYPEDEF

Representation of an arc in the network graph.

# Fields
$TYPEDFIELDS
"""
@kwdef struct NetworkArc{C<:AbstractArcCostFunction,K}
    "travel time in number of discrete time steps (0 if less than the time discretization step)"
    travel_time_steps::Int
    "capacity of the arc (in size units)"
    capacity::Int = typemax(Int)
    "cost function associated with the arc"
    cost::C
    "additional information associated with the arc"
    info::K = nothing
end

"""
A predefined `NetworkArc` representing a zero-cost, zero-duration transition (e.g., waiting at a node).
"""
const SHORTCUT_ARC = NetworkArc(; travel_time_steps=0, cost=LinearArcCost(0.0))

function Base.show(io::IO, arc::NetworkArc)
    return print(
        io,
        "NetworkArc(",
        "capacity=$(arc.capacity == typemax(Int) ? "∞" : string(arc.capacity)), ",
        "cost=$(arc.cost), ",
        "info=$(arc.info)",
        ")",
    )
end

# Conversion constructor to widen the cost type parameter
# This allows automatic conversion to union types
function NetworkArc{C,K}(arc::NetworkArc) where {C<:AbstractArcCostFunction,K}
    return NetworkArc{C,K}(;
        capacity=arc.capacity,
        travel_time=arc.travel_time_steps,
        cost=arc.cost,
        info=arc.info,
    )
end

"""
$TYPEDSIGNATURES

Return the travel duration (in discrete steps) associated with the arc.
"""
travel_time_steps(arc::NetworkArc) = arc.travel_time_steps

"""
$TYPEDSIGNATURES

Evaluate the unit or fixed cost component of the arc's cost function.
This is a base dispatcher; specific implementations for concrete types return relevant rates.
"""
function evaluate(arc_f::AbstractArcCostFunction)
    return 0.0
end

function evaluate(arc_f::LinearArcCost)
    return arc_f.cost_per_unit_size
end

function evaluate(arc_f::BinPackingArcCost)
    return arc_f.cost_per_bin
end
