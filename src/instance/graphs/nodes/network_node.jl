"""
$TYPEDEF

A node in the spatial network graph.
Nodes represent physical locations and can serve as origins or destinations for commodities.

# Fields
$TYPEDFIELDS
"""
struct NetworkNode{J,N<:AbstractNodeCostFunction}
    "unique identifier for the node"
    id::String
    "type of node: :origin, :destination, or :other"
    node_type::Symbol
    cost::Float64
    "capacity of the node (in size units)"
    capacity::Int
    "additional information associated with the node"
    info::J
    "node cost function for this node"
    node_cost::N

    function NetworkNode{J,N}(
        id, node_type, cost, capacity, info, node_cost
    ) where {J,N<:AbstractNodeCostFunction}
        if node_type ∉ (:origin, :destination, :other)
            throw(
                ArgumentError(
                    "node_type must be :origin, :destination, or :other, got :$node_type"
                ),
            )
        end
        return new{J,N}(id, node_type, cost, capacity, info, node_cost)
    end
end

"""
$TYPEDSIGNATURES

Constructor for `NetworkNode`.
# Node Types (Symbol)
- `:origin`: A entry point for commodities.
- `:destination`: An exit point for commodities.
- `:other`: An intermediate or transhipment point.
"""
function NetworkNode(;
    id::String,
    node_type::Symbol,
    cost::Float64=0.0,
    capacity::Int=typemax(Int),
    info=nothing,
    node_cost::AbstractNodeCostFunction=NoNodeCost(),
)
    return NetworkNode{typeof(info),typeof(node_cost)}(
        id, node_type, cost, capacity, info, node_cost
    )
end

function Base.show(io::IO, node::NetworkNode)
    return print(
        io,
        "NetworkNode(",
        "id=$(node.id), ",
        "node_type=$(node.node_type), ",
        "cost=$(node.cost), ",
        "capacity=$(node.capacity == typemax(Int) ? "∞" : string(node.capacity)), ",
        "info=$(node.info), ",
        "node_cost=$(node.node_cost)",
        ")",
    )
end
