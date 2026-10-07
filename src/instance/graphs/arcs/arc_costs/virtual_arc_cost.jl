"""
$TYPEDEF

Cost function of the virtual arcs linking the endpoint copies of a split node to its hub
(see [`Instance`](@ref)).
A virtual arc has no cost, no bins and no capacity limit, and it is never charged a node cost.
"""
struct VirtualArcCost <: AbstractArcCostFunction end

"""
$TYPEDSIGNATURES
"""
evaluate(::VirtualArcCost, ::Vector{<:LightCommodity}; presorted::Bool=false) = 0.0

function incremental_cost(
    ::VirtualArcCost, ::Vector{C}, ::Vector{C}
) where {C<:LightCommodity}
    return 0.0
end

incremental_cost(::VirtualArcCost, ::Nothing, ::Vector{<:LightCommodity}) = 0.0

function incremental_cost_with_size(
    ::VirtualArcCost, ::Vector{C}, ::Vector{C}, ::Float64
) where {C<:LightCommodity}
    return 0.0
end

lower_bound_incremental_cost_with_order(::VirtualArcCost, _, ::Order) = 0.0
