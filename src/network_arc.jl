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

@kwdef struct NetworkArc{C<:AbstractArcCostFunction,K}
    origin_id::String
    destination_id::String
    capacity::Int = typemax(Int)
    cost::C
    info::K = nothing
end
