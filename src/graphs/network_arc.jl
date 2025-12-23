# network garph should be a multigraph, transformed into a simple graph for time space an travel time graphs
# MixedArcCostFunction

# ideally, non decreasing with size
abstract type AbstractArcCostFunction end

struct LinearArcCost <: AbstractArcCostFunction
    cost_per_unit_size::Float64
end

struct BinPackingArcCost <: AbstractArcCostFunction
    cost_per_bin::Float64
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

travel_time_steps(arc::NetworkArc) = arc.travel_time_steps

function evaluate(arc_f::AbstractArcCostFunction)
    return 0.0
end

function evaluate(arc_f::LinearArcCost)
    return arc_f.cost_per_unit_size
end

function evaluate(arc_f::BinPackingArcCost)
    return arc_f.cost_per_bin
end
