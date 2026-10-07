"""
$TYPEDEF

User-facing description of a node of the network, converted to a [`NetworkNode`](@ref)
by [`collect_nodes`](@ref) when an [`Instance`](@ref) is built.

The role of a node is derived when the instance is built, from the commodities that start or
end at it and from the arcs that enter or leave it. A node that is both a commodity endpoint
and a crossing point is split internally into a hub and endpoint copies linked by virtual
arcs, without any change of cost. With `transit=false` the node can never be an intermediate
node of a route: the arcs that could only be used to cross it (an incoming arc when no
commodity ends there, an outgoing arc when no commodity starts there) are not created.

# Fields
$TYPEDFIELDS
"""
struct Node{J,N<:AbstractNodeCostFunction}
    "unique identifier for the node"
    id::String
    "capacity of the node (in size units)"
    capacity::Int
    "additional information associated with the node"
    info::J
    "node cost function for this node"
    node_cost::N
    "whether routes may cross the node (`false`: it can only be the origin or destination of a route)"
    transit::Bool
end

"""
$TYPEDSIGNATURES

Keyword constructor for [`Node`](@ref).

The `node_type` keyword is deprecated and ignored, node roles are now derived from the
commodities and arcs (use `transit=false` to forbid crossing a node).
"""
function Node(;
    id::AbstractString,
    capacity::Int=typemax(Int),
    info=nothing,
    node_cost::AbstractNodeCostFunction=NoNodeCost(),
    transit::Bool=true,
    node_type=nothing,
)
    isnothing(node_type) || Base.depwarn(
        "the `node_type` keyword of `Node` is ignored, node roles are now derived from the commodities and arcs (use `transit=false` for a node that cannot be crossed)",
        :Node,
    )
    return Node{typeof(info),typeof(node_cost)}(
        String(id), capacity, info, node_cost, transit
    )
end

function Base.show(io::IO, node::Node)
    return print(
        io,
        "Node(",
        "id=$(node.id), ",
        "capacity=$(node.capacity == typemax(Int) ? "∞" : string(node.capacity)), ",
        "info=$(node.info), ",
        "node_cost=$(node.node_cost), ",
        "transit=$(node.transit)",
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
Converts the user [`Node`](@ref)s to [`NetworkNode`](@ref)s, keeping their positions
(the `input_index` of each converted node is its position). The converted nodes are typed
`:other`, the roles are derived when the instance is built (see [`Node`](@ref)).
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
            node.id, :other, node.capacity, node.info, node.node_cost, i
        ) for (i, node) in enumerate(nodes)
    ]
end
