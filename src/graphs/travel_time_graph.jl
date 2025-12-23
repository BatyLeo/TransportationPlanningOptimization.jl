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
end

function Base.show(io::IO, g::TravelTimeGraph)
    return println(
        io,
        "Travel-Time Graph with $(Graphs.nv(g.graph)) nodes and $(Graphs.ne(g.graph)) arcs",
    )
end

#

function MetaGraphsNext.haskey(
    travel_time_graph::TravelTimeGraph,
    args...
)
    return haskey(travel_time_graph.graph, args...)
end

function Graphs.add_edge!(
    travel_time_graph::TravelTimeGraph,
    u::Tuple{String,Int},
    v::Tuple{String,Int},
    arc::NetworkArc,
)
    return Graphs.add_edge!(travel_time_graph.graph, u, v, arc)
end

function Graphs.add_vertex!(
    travel_time_graph::TravelTimeGraph,
    u::Tuple{String,Int},
    node::NetworkNode,
)
    return Graphs.add_vertex!(travel_time_graph.graph, u, node)
end

"""
$TYPEDSIGNATURES

Get the time horizon of the travel-time graph.
"""
function time_horizon(travel_time_graph::TravelTimeGraph)
    return 0:(travel_time_graph.max_time_steps)
end

# TODO: in the outbound case, where is_date_arrival=false, this may need to be adapted
"""
$TYPEDSIGNATURES

Add a network node to the travel-time graph, creating timed copies as needed.
"""
function add_network_node!(
    travel_time_graph::TravelTimeGraph,
    node::NetworkNode,
    node_to_bundles_map::Dict{String, Vector{B}},
) where {B<:Bundle}
    if node.node_type == :destination
        # Only add destinations at τ=0
        Graphs.add_vertex!(travel_time_graph.graph, (node.id, 0), node)
    elseif node.node_type == :origin
        # TODO: make sure this is really needed
        # Only add origins up to the maximum delivery time of orders originating here
        max_duration = maximum(
            order.max_delivery_time_step for bundle in
                                             get(node_to_bundles_map, node.id, []) for
            order in bundle.orders
        )
        for τ in 0:max_duration
            Graphs.add_vertex!(travel_time_graph, (node.id, τ), node)
        end

        for τ in 1:(travel_time_graph.max_time_steps)
            u = (node.id, τ - 1)
            v = (node.id, τ)
            if haskey(travel_time_graph, u) && haskey(travel_time_graph, v)
                Graphs.add_edge!(travel_time_graph, u, v, SHORTCUT_ARC)
            end
        end
    else
        # Add all other nodes at every time step
        for τ in time_horizon(travel_time_graph)
            Graphs.add_vertex!(travel_time_graph, (node.id, τ), node)
        end
    end

    return nothing
end

"""
$TYPEDSIGNATURES

Add a network arc to the travel-time graph, creating timed copies as needed.
"""
function add_network_arc!(
    travel_time_graph::TravelTimeGraph,
    origin::NetworkNode,
    destination::NetworkNode,
    arc::NetworkArc,
)
    T = travel_time_graph.max_time_steps

    for τ_u in time_horizon(travel_time_graph)
        u = (origin.id, τ_u)
        τ_v = τ_u - travel_time_steps(arc)
        v = (destination.id, τ_v)
        if haskey(travel_time_graph, u) && haskey(travel_time_graph, v)
            Graphs.add_edge!(travel_time_graph, u, v, arc)
        end
    end
    return nothing
end

function TravelTimeGraph(network_graph::NetworkGraph, bundles::Vector{<:Bundle})
    # Initialize empty TimeTravelGraph
    graph = MetaGraph(
        Graphs.DiGraph();
        label_type=Tuple{String,Int},
        vertex_data_type=NetworkNode,
        edge_data_type=NetworkArc,
    )

    max_time_steps = maximum(
        order.max_delivery_time_step for bundle in bundles for order in bundle.orders
    )

    travel_time_graph = TravelTimeGraph(graph, max_time_steps)

    node_to_bundles_map = compute_node_to_bundles_map(bundles)
    # Fill with timed copies of network nodes
    for node_id in MetaGraphsNext.labels(network_graph.graph)
        node = network_graph.graph[node_id]
        add_network_node!(travel_time_graph, node, node_to_bundles_map)
    end

    # Connect timed nodes according to network arcs
    for (u_id, v_id) in MetaGraphsNext.edge_labels(network_graph.graph)
        u = network_graph.graph[u_id]
        v = network_graph.graph[v_id]
        arc = network_graph.graph[u_id, v_id]
        add_network_arc!(travel_time_graph, u, v, arc)
    end

    return travel_time_graph
end
