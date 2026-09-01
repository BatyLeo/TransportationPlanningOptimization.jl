"""
$TYPEDSIGNATURES

Infer the node cost types present in a vector of nodes by scanning their actual cost function
types. Returns a tuple of unique cost types found.
"""
function infer_node_cost_types(nodes::Vector{<:NetworkNode})
    return Tuple(unique(typeof(n.node_cost) for n in nodes))
end

"""
$TYPEDSIGNATURES

Collect nodes into a type-stable vector with the specified node cost types.
Mirrors [`collect_arcs`](@ref): when an instance mixes several
[`AbstractNodeCostFunction`](@ref) subtypes, the resulting `Vector{NetworkNode{J, CostUnion}}`
keeps Julia's small-union optimization in play (up to 4 concrete types).

# Arguments
- `cost_types`: a tuple or Union of node cost function types
  - Tuple syntax: `(NoNodeCost, MyNodeCost)`
  - Union syntax: `Union{NoNodeCost, MyNodeCost}`
- `nodes`: vector of `NetworkNode` objects with potentially different cost types
- `validate`: whether to validate that all node cost types are included (default: true)
"""
function collect_nodes(cost_types::Tuple, nodes::Vector{<:NetworkNode}; validate::Bool=true)
    CostUnion = Union{cost_types...}
    return collect_nodes(CostUnion, nodes; validate=validate)
end

function collect_nodes(
    union_types::Type{CostUnion}, nodes::Vector{<:NetworkNode}; validate::Bool=true
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
