struct NetworkNode{J}
    id::String
    node_type::Symbol
    cost::Float64
    capacity::Int
    info::J

    function NetworkNode{J}(id, node_type, cost, capacity, info) where {J}
        if node_type ∉ (:origin, :destination, :other)
            throw(ArgumentError("node_type must be :origin, :destination, or :other, got :$node_type"))
        end
        return new{J}(id, node_type, cost, capacity, info)
    end
end

function NetworkNode(;
    id::String,
    node_type::Symbol,
    cost::Float64=0.0,
    capacity::Int=typemax(Int),
    info=nothing,
)
    return NetworkNode{typeof(info)}(id, node_type, cost, capacity, info)
end

function Base.show(io::IO, node::NetworkNode)
    return print(
        io,
        "NetworkNode(",
        "id=$(node.id), ",
        "node_type=$(node.node_type), ",
        "cost=$(node.cost), ",
        "capacity=$(node.capacity == typemax(Int) ? "∞" : string(node.capacity)), ",
        "info=$(node.info)",
        ")",
    )
end
