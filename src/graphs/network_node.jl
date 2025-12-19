abstract type AbstractNodeType end

struct Origin <: AbstractNodeType end
struct Destination <: AbstractNodeType end
struct Other <: AbstractNodeType end
@wrapped struct NodeType <: WrappedUnion
    union::Union{Origin,Destination,Other}
end

Base.show(io::IO, ::Origin) = print(io, "Origin")
Base.show(io::IO, ::Destination) = print(io, "Destination")
Base.show(io::IO, ::Other) = print(io, "Other")

@kwdef struct NetworkNode{J}
    id::String
    type::NodeType = NodeType(Other())
    cost::Float64 = 0.0
    capacity::Int = typemax(Int)
    info::J = nothing
end

function Base.show(io::IO, node::NetworkNode)
    return print(
        io,
        "NetworkNode(",
        "id=$(node.id), ",
        "type=$(node.type), ",
        "cost=$(node.cost), ",
        "capacity=$(node.capacity == typemax(Int) ? "∞" : string(node.capacity)), ",
        "info=$(node.info)",
        ")",
    )
end
