"""
$TYPEDEF

A collection of `Order`s that share the same origin and destination.
While orders in a bundle can have different delivery dates, they should follow the same path (in the travel time graph).

# Fields
$TYPEDFIELDS
"""
struct Bundle{O<:Order}
    orders::Vector{O}
    origin_id::String
    destination_id::String
end

function Bundle(;
    orders::Vector{O}, origin_id::String, destination_id::String
) where {O<:Order}
    return Bundle{O}(orders, origin_id, destination_id)
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

Compute the total size of all commodities in the bundle.
"""
function total_size(bundle::Bundle)
    return sum(total_size(order) for order in bundle.orders; init=0.0)
end
