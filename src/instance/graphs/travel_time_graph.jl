"""
$TYPEDEF

# Fields
$TYPEDFIELDS
"""
struct TravelTimeGraph{G<:MetaGraph}
    "underlying time-expanded graph"
    graph::G
    "Maximum duration of a delivery"
    max_time_steps::Int
    "Cost matrix between timed nodes (sparse)"
    cost_matrix::SparseMatrixCSC{Float64,Int}
end

function Base.show(io::IO, g::TravelTimeGraph)
    return println(
        io,
        "Travel-Time Graph with $(Graphs.nv(g.graph)) nodes and $(Graphs.ne(g.graph)) arcs",
    )
end

"""
$TYPEDSIGNATURES

Return node metadata for `label`.
"""
function Base.getindex(travel_time_graph::TravelTimeGraph, label)
    return travel_time_graph.graph[label]
end

"""
$TYPEDSIGNATURES

Return edge metadata for the edge between `label_1` and `label_2`.
"""
function Base.getindex(travel_time_graph::TravelTimeGraph, label_1, label_2)
    return travel_time_graph.graph[label_1, label_2]
end

"""
$TYPEDSIGNATURES

Check if the travel-time graph has a vertex with the given `label`.
"""
function MetaGraphsNext.haskey(travel_time_graph::TravelTimeGraph, label)
    return haskey(travel_time_graph.graph, label)
end

"""
$TYPEDSIGNATURES

Check if the travel-time graph has an edge between `label_1` and `label_2`.
"""
function MetaGraphsNext.haskey(travel_time_graph::TravelTimeGraph, label_1, label_2)
    return haskey(travel_time_graph.graph, label_1, label_2)
end

"""
$TYPEDSIGNATURES

Add an arc between `u` and `v` with metadata `arc` to the travel-time graph.
"""
function Graphs.add_edge!(
    travel_time_graph::TravelTimeGraph,
    u::Tuple{String,Int},
    v::Tuple{String,Int},
    arc::NetworkArc,
)
    return Graphs.add_edge!(travel_time_graph.graph, u, v, arc)
end

"""
$TYPEDSIGNATURES

Add a vertex with label `u` and metadata `node` to the travel-time graph.
"""
function Graphs.add_vertex!(
    travel_time_graph::TravelTimeGraph, u::Tuple{String,Int}, node::NetworkNode
)
    return Graphs.add_vertex!(travel_time_graph.graph, u, node)
end

"""
$TYPEDSIGNATURES
"""
function Graphs.has_edge(
    travel_time_graph::TravelTimeGraph, code_1::Integer, code_2::Integer
)
    return Graphs.has_edge(travel_time_graph.graph, code_1, code_2)
end

"""
$TYPEDSIGNATURES
"""
function Graphs.has_vertex(travel_time_graph::TravelTimeGraph, code::Integer)
    return Graphs.has_vertex(travel_time_graph.graph, code)
end

"""
$TYPEDSIGNATURES

Get the number of vertices in the travel-time graph.
"""
function Graphs.nv(travel_time_graph::TravelTimeGraph)
    return Graphs.nv(travel_time_graph.graph)
end

"""
$TYPEDSIGNATURES

Get the number of edges in the travel-time graph.
"""
function Graphs.ne(travel_time_graph::TravelTimeGraph)
    return Graphs.ne(travel_time_graph.graph)
end

"""
$TYPEDSIGNATURES

Get the weights (cost matrix) of the travel-time graph.
"""
function Graphs.weights(travel_time_graph::TravelTimeGraph)
    return travel_time_graph.cost_matrix
end

"""
$TYPEDSIGNATURES

Get the time horizon of the travel-time graph.
"""
function time_horizon(travel_time_graph::TravelTimeGraph)
    return 0:(travel_time_graph.max_time_steps)
end

"""
$TYPEDSIGNATURES

Add timed copies of a network node to the travel-time graph.
"""
function _add_network_node_to_travel_time_graph!(
    g::MetaGraph,
    node::NetworkNode,
    node_to_bundles_map::Dict{String,Vector{B}},
    max_time_steps::Int,
) where {B<:Bundle}
    if node.node_type == :destination
        # Only add destinations at τ=0
        Graphs.add_vertex!(g, (node.id, 0), node)
    elseif node.node_type == :origin
        # TODO: make sure this is really needed
        # Only add origins up to the maximum delivery time of orders originating here
        max_duration = maximum(
            order.max_delivery_time_step for bundle in
                                             get(node_to_bundles_map, node.id, []) for
            order in bundle.orders;
            init=-1,
        )
        for τ in 0:max_duration
            Graphs.add_vertex!(g, (node.id, τ), node)
        end

        for τ in 1:max_time_steps
            u = (node.id, τ - 1)
            v = (node.id, τ)
            if haskey(g, u) && haskey(g, v)
                Graphs.add_edge!(g, u, v, SHORTCUT_ARC)
            end
        end
    else
        # Add all other nodes at every time step
        for τ in 0:max_time_steps
            Graphs.add_vertex!(g, (node.id, τ), node)
        end
    end

    return nothing
end

"""
$TYPEDSIGNATURES

Add arcs corresponding to a network arc to the travel-time graph.
"""
function _add_network_arc_to_travel_time_graph!(
    g::MetaGraph,
    origin::NetworkNode,
    destination::NetworkNode,
    arc::NetworkArc,
    max_time_steps::Int,
)
    for τ_u in 0:max_time_steps
        u = (origin.id, τ_u)
        τ_v = τ_u - travel_time_steps(arc)
        v = (destination.id, τ_v)
        if haskey(g, u) && haskey(g, v)
            Graphs.add_edge!(g, u, v, arc)
        end
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Construct a `TravelTimeGraph` from a `NetworkGraph` and a set of `Bundle`s.
"""
function TravelTimeGraph(network_graph::NetworkGraph, bundles::Vector{<:Bundle})
    # Initialize empty TimeTravelGraph
    graph = MetaGraph(
        Graphs.DiGraph();
        label_type=Tuple{String,Int},
        vertex_data_type=NetworkNode,
        edge_data_type=NetworkArc,
        default_weight=Inf,
    )

    max_time_steps = maximum(
        order.max_delivery_time_step for bundle in bundles for order in bundle.orders
    )

    node_to_bundles_map = compute_node_to_bundles_map(bundles)

    # Fill with timed copies of network nodes
    for node_id in MetaGraphsNext.labels(network_graph.graph)
        node = network_graph.graph[node_id]
        _add_network_node_to_travel_time_graph!(
            graph, node, node_to_bundles_map, max_time_steps
        )
    end

    # Connect timed nodes according to network arcs
    for (u_id, v_id) in MetaGraphsNext.edge_labels(network_graph.graph)
        u = network_graph.graph[u_id]
        v = network_graph.graph[v_id]
        arc = network_graph.graph[u_id, v_id]
        _add_network_arc_to_travel_time_graph!(graph, u, v, arc, max_time_steps)
    end

    # Build cost matrix with random values per timed edge
    n = Graphs.nv(graph)
    I = Int[]
    J = Int[]
    V = Float64[]
    for (u_id, v_id) in MetaGraphsNext.edge_labels(graph)
        i = MetaGraphsNext.code_for(graph, u_id)
        j = MetaGraphsNext.code_for(graph, v_id)
        push!(I, i)
        push!(J, j)
        push!(V, 0.0)
    end
    cost_matrix = sparse(I, J, V, n, n)

    return TravelTimeGraph(graph, max_time_steps, cost_matrix)
end
