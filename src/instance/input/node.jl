"""
$TYPEDEF

User-facing description of a node of the network, converted to a [`NetworkNode`](@ref)
by [`collect_nodes`](@ref) when an [`Instance`](@ref) is built.

# Fields
$TYPEDFIELDS
"""
struct Node{J,N<:AbstractNodeCostFunction}
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

    function Node{J,N}(
        id, node_type, capacity, info, node_cost
    ) where {J,N<:AbstractNodeCostFunction}
        _check_node_type(node_type)
        return new{J,N}(id, node_type, capacity, info, node_cost)
    end
end

"""
$TYPEDSIGNATURES

Keyword constructor for [`Node`](@ref).

# Node Types (Symbol)
- `:origin`: An entry point for commodities.
- `:destination`: An exit point for commodities.
- `:other`: An intermediate or transhipment point.
"""
function Node(;
    id::AbstractString,
    node_type::Symbol,
    capacity::Int=typemax(Int),
    info=nothing,
    node_cost::AbstractNodeCostFunction=NoNodeCost(),
)
    return Node{typeof(info),typeof(node_cost)}(
        String(id), node_type, capacity, info, node_cost
    )
end

function Base.show(io::IO, node::Node)
    return print(
        io,
        "Node(",
        "id=$(node.id), ",
        "node_type=$(node.node_type), ",
        "capacity=$(node.capacity == typemax(Int) ? "∞" : string(node.capacity)), ",
        "info=$(node.info), ",
        "node_cost=$(node.node_cost)",
        ")",
    )
end

"""
$TYPEDSIGNATURES

Infer the node cost types present in a vector of nodes by scanning their actual cost function
types. Returns a tuple of unique cost types found.
"""
function infer_node_cost_types(nodes::Vector{<:Node})
    return Tuple(unique(typeof(n.node_cost) for n in nodes))
end

"""
$TYPEDSIGNATURES

Collect nodes into a type-stable vector with the specified node cost types.
Converts the user [`Node`](@ref)s to [`NetworkNode`](@ref)s, keeping their positions.
Mirrors [`collect_arcs`](@ref): when an instance mixes several
[`AbstractNodeCostFunction`](@ref) subtypes, the resulting `Vector{NetworkNode{J, CostUnion}}`
keeps Julia's small-union optimization in play (up to 4 concrete types).

# Arguments
- `cost_types`: a tuple or Union of node cost function types
  - Tuple syntax: `(NoNodeCost, MyNodeCost)`
  - Union syntax: `Union{NoNodeCost, MyNodeCost}`
- `nodes`: vector of `Node` objects with potentially different cost types
- `validate`: whether to validate that all node cost types are included (default: true)
"""
function collect_nodes(cost_types::Tuple, nodes::Vector{<:Node}; validate::Bool=true)
    CostUnion = Union{cost_types...}
    return collect_nodes(CostUnion, nodes; validate=validate)
end

function collect_nodes(
    union_types::Type{CostUnion}, nodes::Vector{<:Node}; validate::Bool=true
) where {CostUnion}
    if isempty(nodes)
        return NetworkNode{Nothing,CostUnion}[]
    end

    J = typeof(first(nodes).info)

    if validate
        for node in nodes
            cost_type = typeof(node.node_cost)
            if !(cost_type <: CostUnion)
                error("""
                    Node cost type $cost_type found in nodes but not declared.
                    Declared types: $(join(string.(union_types), ", "))

                    You need to add $cost_type to your cost types:
                    collect_nodes(($(join(string.(union_types), ", ")), $cost_type), nodes)
                    """)
            end
        end
    end

    return [
        NetworkNode{J,CostUnion}(
            node.id, node.node_type, node.capacity, node.info, node.node_cost
        ) for node in nodes
    ]
end
