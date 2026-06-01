"""
$TYPEDEF

A representation of the physical (spatial) network graph.
Nodes are identified by `String` labels and store `NetworkNode` metadata.
Edges store `NetworkArc` metadata.

# Fields
$TYPEDFIELDS
"""
struct NetworkGraph{G<:MetaGraph}
    "The underlying MetaGraph mapping node IDs (Strings) to metadata."
    graph::G
end

"""
$TYPEDSIGNATURES

Extract the edge data type stored in a `MetaGraph`.
"""
_metagraph_edge_type(mg::MetaGraph) = valtype(mg.edge_data)

"""
$TYPEDSIGNATURES

Extract the edge data type stored in the underlying graph of a `NetworkGraph`.
"""
_metagraph_edge_type(ng::NetworkGraph) = _metagraph_edge_type(ng.graph)

"""
$TYPEDSIGNATURES

Edge data type used by `TravelTimeGraph`. Widens the `NetworkGraph` edge type
with the shortcut-arc concrete type so the TTG can store both the network's
own arcs and the zero-duration shortcut arcs it adds during construction.
"""
function _ttg_edge_type(ng::NetworkGraph)
    return Union{_metagraph_edge_type(ng),typeof(SHORTCUT_ARC)}
end

"""
$TYPEDSIGNATURES

Constructor for `NetworkGraph`.

Ensures node IDs are unique. Multiple arcs between the same `(origin_id, destination_id)`
pair are accepted: the graph keeps a single edge whose data is auto-promoted to a
`MultiModalArc` carrying every mode declared for that leg.

`arcs` must be concretely typed as `Vector{Tuple{String,String,NA}}` for a single
`NA<:NetworkArc`. Pre-built `MultiModalArc` values are not accepted in the input vector:
multi-modal legs must be expressed as several `NetworkArc` entries sharing the same
`(origin_id, destination_id)` and the constructor handles promotion.

Callers holding a heterogeneously-typed arc vector (for example, mixed cost functions)
should narrow it through [`collect_arcs`](@ref) (or an equivalent step) before calling
this constructor, which is the standard entry path used by [`Instance`](@ref).
"""
function NetworkGraph(
    nodes::Vector{<:NetworkNode}, arcs::Vector{Tuple{String,String,NA}}
) where {NA<:NetworkArc}
    network_graph = MetaGraph(
        Graphs.DiGraph();
        label_type=String,
        vertex_data_type=eltype(nodes),
        edge_data_type=Union{NA,MultiModalArc{NA}},
    )
    _fill_network_graph!(network_graph, nodes, arcs)
    return NetworkGraph(network_graph)
end

function _fill_network_graph!(network_graph, nodes, arcs)
    for node in nodes
        if haskey(network_graph, node.id)
            prev_idx = findfirst(x -> x.id == node.id, nodes)
            prev_node = prev_idx === nothing ? "unknown" : nodes[prev_idx]
            throw(ErrorException("""Duplicate node id detected:
                  - node id           : $(node.id)
                  - first occurrence  : index $(prev_idx), record: $(prev_node)
                  - duplicate record  : $(node)
                Please ensure each row has a unique 'id' value.
            """))
        end
        Graphs.add_vertex!(network_graph, node.id, node)
    end
    for (origin_id, destination_id, arc) in arcs
        if MetaGraphsNext.haskey(network_graph, origin_id, destination_id)
            existing = network_graph[origin_id, destination_id]
            network_graph[origin_id, destination_id] = _promote_to_multi_modal(
                existing, arc
            )
        else
            Graphs.add_edge!(network_graph, origin_id, destination_id, arc)
        end
    end
    return nothing
end

# Auto-promote arc edge data when a duplicate (origin, destination) is added to a
# `NetworkGraph`. The resulting `MultiModalArc` collects every mode declared for the leg.

function _promote_to_multi_modal(existing::NetworkArc, new_arc::NetworkArc)
    return MultiModalArc([existing, new_arc])
end

function _promote_to_multi_modal(existing::MultiModalArc, new_arc::NetworkArc)
    return MultiModalArc(vcat(existing.modes, [new_arc]))
end

function _promote_to_multi_modal(existing::NetworkArc, new_arc::MultiModalArc)
    return MultiModalArc(vcat([existing], new_arc.modes))
end

function _promote_to_multi_modal(existing::MultiModalArc, new_arc::MultiModalArc)
    return MultiModalArc(vcat(existing.modes, new_arc.modes))
end

function Base.show(io::IO, ng::NetworkGraph)
    return println(
        io,
        "Network Graph with $(Graphs.nv(ng.graph)) nodes and $(Graphs.ne(ng.graph)) arcs",
    )
end
