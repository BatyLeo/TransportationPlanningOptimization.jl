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

"""
$TYPEDSIGNATURES

Get the time horizon of the travel-time graph.
"""
function time_horizon(travel_time_graph::TravelTimeGraph)
    return 0:(travel_time_graph.max_time_steps)
end

# TODO: not all nodes should be duplicated, destinations can only appear if τ=0
function add_network_node!(travel_time_graph::TravelTimeGraph, node::NetworkNode)
    if node.node_type == :destination
        # Only add destinations at τ=0
        Graphs.add_vertex!(travel_time_graph.graph, (node.id, 0), node)
    else
        # TODO:
        #= in the case of origins, we may want to only add up to the maximum duration of
        bundles starting from this origin =#

        # Add all other nodes at every time step
        for τ in time_horizon(travel_time_graph)
            Graphs.add_vertex!(travel_time_graph.graph, (node.id, τ), node)
        end
    end

    # Add shortcut arcs
    if node.node_type == :origin
        for τ in 1:(travel_time_graph.max_time_steps)
            u = (node.id, τ - 1)
            v = (node.id, τ)
            Graphs.add_edge!(travel_time_graph.graph, u, v, SHORTCUT_ARC)
        end
    end
    return nothing
end

function add_network_arc!(
    travel_time_graph::TravelTimeGraph,
    origin::NetworkNode,
    destination::NetworkNode,
    arc::NetworkArc,
)
    (; max_time_steps) = travel_time_graph
    T = travel_time_graph.max_time_steps
    for τ in time_horizon(travel_time_graph)
        t = T - τ
        u_t = (origin.id, t)
        destination_time = t + arc.travel_time
        if destination_time > max_time_steps
            destination_time -= max_time_steps
        end
        v_t = (destination.id, destination_time)

        if MetaGraphsNext.haskey(travel_time_graph.graph, u_t) &&
            MetaGraphsNext.haskey(travel_time_graph.graph, v_t)
            was_added = Graphs.add_edge!(travel_time_graph.graph, u_t, v_t, arc)
            if !was_added
                throw(
                    ErrorException(
                        "Unable to add edge from $u_t to $v_t to travel-time graph"
                    ),
                )
            end
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

    # Fill with timed copies of network nodes
    for node_id in MetaGraphsNext.labels(network_graph.graph)
        node = network_graph.graph[node_id]
        add_network_node!(travel_time_graph, node)
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
