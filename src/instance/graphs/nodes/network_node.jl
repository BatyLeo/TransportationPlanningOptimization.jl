"""
$TYPEDSIGNATURES

Throw an `ArgumentError` unless `node_type` is `:origin`, `:destination` or `:other`.
Shared by the user-facing [`Node`](@ref) and the internal [`NetworkNode`](@ref).
"""
function _check_node_type(node_type)
    if node_type ∉ (:origin, :destination, :other)
        throw(
            ArgumentError(
                "node_type must be :origin, :destination, or :other, got $(repr(node_type))"
            ),
        )
    end
    return nothing
end

"""
$TYPEDEF

A node in the spatial network graph.
Nodes represent physical locations and can serve as origins or destinations for commodities.
This is the internal vertex data of the graphs, users describe nodes with [`Node`](@ref).

# Fields
$TYPEDFIELDS
"""
struct NetworkNode{J,N<:AbstractNodeCostFunction}
    "unique identifier for the node"
    id::String
    "type of node: :origin, :destination, or :other"
    node_type::Symbol
    "capacity of the node (in size units)"
    capacity::Int
    "additional information associated with the node"
    info::J
    "node cost function for this node"
    node_cost::N

    function NetworkNode{J,N}(
        id, node_type, capacity, info, node_cost
    ) where {J,N<:AbstractNodeCostFunction}
        _check_node_type(node_type)
        return new{J,N}(id, node_type, capacity, info, node_cost)
    end
end

"""
$TYPEDSIGNATURES

Constructor for [`NetworkNode`](@ref).
# Node Types (Symbol)
- `:origin`: An entry point for commodities.
- `:destination`: An exit point for commodities.
- `:other`: An intermediate or transhipment point.
"""
function NetworkNode(;
    id::String,
    node_type::Symbol,
    capacity::Int=typemax(Int),
    info=nothing,
    node_cost::AbstractNodeCostFunction=NoNodeCost(),
)
    return NetworkNode{typeof(info),typeof(node_cost)}(
        id, node_type, capacity, info, node_cost
    )
end

function Base.show(io::IO, node::NetworkNode)
    return print(
        io,
        "NetworkNode(",
        "id=$(node.id), ",
        "node_type=$(node.node_type), ",
        "capacity=$(node.capacity == typemax(Int) ? "∞" : string(node.capacity)), ",
        "info=$(node.info), ",
        "node_cost=$(node.node_cost)",
        ")",
    )
end
