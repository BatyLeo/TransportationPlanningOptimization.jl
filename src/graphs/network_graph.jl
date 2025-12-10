struct NetworkGraph{G<:MetaGraph}
    graph::G
end

function NetworkGraph(nodes::Vector{<:NetworkNode}, arcs::Vector{<:NetworkArc})
    network_graph = MetaGraph(
        Graphs.DiGraph();
        label_type=String,
        vertex_data_type=eltype(nodes),
        edge_data_type=eltype(arcs),
        graph_data=Dict{Symbol,Int}(),
    )

    for node in nodes
        if haskey(network_graph, node.id)
            prev_idx = findfirst(x -> x.id == node.id, nodes)
            prev_node = prev_idx === nothing ? "unknown" : nodes[prev_idx]
            throw(ErrorException("""Duplicate node id detected in $(nodes_file):
                  - node id           : $(node.id)
                  - first occurrence  : index $(prev_idx), record: $(prev_node)
                  - duplicate record  : $(node)
                Please ensure each row in $(nodes_file) has a unique 'id' value,
                or remove/merge duplicate entries before importing.
            """))
        end
        Graphs.add_vertex!(network_graph, node.id, node)
    end

    for arc in arcs
        if MetaGraphsNext.haskey(network_graph, arc.origin_id, arc.destination_id)
            throw(
                ErrorException(
                    """Duplicate arc detected in $(legs_file):
                        - origin      : $(arc.origin_id)
                        - destination : $(arc.destination_id)
                        - type        : $(arc.info.arc_type)
                        - record      : $(arc)
                        An arc with the same origin and destination is already present in the graph.
                        Please check $(legs_file) for duplicate entries or adjust the data/import logic.
                    """,
                ),
            )
        end
        Graphs.add_edge!(network_graph, arc.origin_id, arc.destination_id, arc)
    end

    return NetworkGraph(network_graph)
end

function Base.show(io::IO, ng::NetworkGraph)
    return println(
        io, "NetworkGraph with $(Graphs.nv(ng.graph)) nodes and $(Graphs.ne(ng.graph)) arcs"
    )
end
