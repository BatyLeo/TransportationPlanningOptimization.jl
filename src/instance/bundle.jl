"""
$TYPEDEF

A collection of `Order`s that share the same origin and destination.
While orders in a bundle can have different delivery dates, they should follow the same path
(in the travel time graph).

# Fields
$TYPEDFIELDS
"""
struct Bundle{O<:Order}
    "list of orders in the bundle"
    orders::Vector{O}
    "id of the origin node"
    origin_id::String
    "id of the destination node"
    destination_id::String
    "set of node IDs that are forbidden for this bundle (cannot be traversed)"
    forbidden_nodes::Set{String}
    "set of arc (origin_id, destination_id) pairs that are forbidden for this bundle"
    forbidden_arcs::Set{Tuple{String,String}}
    "precomputed sum of all commodity sizes across all orders"
    total_size::Float64

    function Bundle{O}(
        orders::Vector{O},
        origin_id::String,
        destination_id::String,
        forbidden_nodes::Set{String},
        forbidden_arcs::Set{Tuple{String,String}},
    ) where {O<:Order}
        ts = sum(total_size(o) for o in orders; init=0.0)
        return new{O}(
            orders, origin_id, destination_id, forbidden_nodes, forbidden_arcs, ts
        )
    end
end

function Bundle(
    orders::Vector{O},
    origin_id::String,
    destination_id::String,
    forbidden_nodes::Set{String},
    forbidden_arcs::Set{Tuple{String,String}},
) where {O<:Order}
    return Bundle{O}(orders, origin_id, destination_id, forbidden_nodes, forbidden_arcs)
end

"""
$TYPEDSIGNATURES

Construct a `Bundle` from a list of `Order`s and the shared origin and destination node IDs.
The `forbidden_nodes` and `forbidden_arcs` fields are optional and can be used to specify additional
constraints on the paths that can be taken by this bundle.
"""
function Bundle(;
    orders::Vector{O},
    origin_id::String,
    destination_id::String,
    forbidden_nodes::Set{String}=Set{String}(),
    forbidden_arcs::Set{Tuple{String,String}}=Set{Tuple{String,String}}(),
) where {O<:Order}
    return Bundle{O}(orders, origin_id, destination_id, forbidden_nodes, forbidden_arcs)
end

"""
$TYPEDSIGNATURES

Compute a mapping from node IDs to the list of bundles that originate from that node.
"""
function compute_node_to_bundles_map(bundles::Vector{B}) where {B<:Bundle}
    node_to_bundles = Dict{String,Vector{B}}()
    for bundle in bundles
        if haskey(node_to_bundles, bundle.origin_id)
            push!(node_to_bundles[bundle.origin_id], bundle)
        else
            node_to_bundles[bundle.origin_id] = [bundle]
        end
    end
    return node_to_bundles
end

"""
$TYPEDSIGNATURES

Total size of all commodities in the bundle (precomputed at construction).
"""
total_size(bundle::Bundle) = bundle.total_size

"""
$TYPEDSIGNATURES

Compute the maximum single-commodity size across all orders in the bundle.
Matches STP's `maxPackSize`, used to sort bundles for the greedy heuristic.
"""
function max_pack_size(bundle::Bundle)
    return maximum(c.size for order in bundle.orders for c in order.commodities; init=0.0)
end
