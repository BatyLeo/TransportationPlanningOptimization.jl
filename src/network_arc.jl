abstract type AbstractArcCostFunction end

struct LinearArcCost <: AbstractArcCostFunction
    cost_per_unit_size::Float64
end

struct BinPackingArcCost <: AbstractArcCostFunction
    cost_per_bin::Float64
    bin_capacity::Int
end

@kwdef struct NetworkArc{C<:AbstractArcCostFunction,K}
    origin_id::String
    destination_id::String
    capacity::Int = typemax(Int)
    cost::C
    info::K = nothing
end
