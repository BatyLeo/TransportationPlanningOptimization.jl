"""
$TYPEDEF

Representation of an arc in the network graph.

# Fields
$TYPEDFIELDS
"""
@kwdef struct Arc{C<:AbstractArcCostFunction,K,T<:Period}
    "id of the origin node"
    origin_id::String
    "id of the destination node"
    destination_id::String
    "travel time in number of discrete time steps (0 if less than the time discretization step)"
    travel_time::T
    "capacity of the arc (in size units)"
    capacity::Int = typemax(Int)
    "cost function associated with the arc"
    cost::C
    "additional information associated with the arc"
    info::K = nothing
end

function Base.show(io::IO, arc::Arc)
    return print(
        io,
        "Arc(",
        "origin_id=$(arc.origin_id), ",
        "destination_id=$(arc.destination_id), ",
        "capacity=$(arc.capacity == typemax(Int) ? "∞" : string(arc.capacity)), ",
        "cost=$(arc.cost), ",
        "info=$(arc.info)",
        ")",
    )
end

# Conversion constructor to widen the cost type parameter
# This allows automatic conversion to union types
function Arc{C,K}(arc::Arc) where {C<:AbstractArcCostFunction,K}
    return Arc{C,K}(;
        origin_id=arc.origin_id,
        destination_id=arc.destination_id,
        capacity=arc.capacity,
        cost=arc.cost,
        info=arc.info,
    )
end
