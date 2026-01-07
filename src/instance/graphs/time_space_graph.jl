"""
$TYPEDEF

A `TimeSpaceGraph` represents a time-expanded version of a network graph, where each node is replicated for each time step in the time horizon.

# Fields
$TYPEDFIELDS
"""
struct TimeSpaceGraph{G}
    "underlying time-expanded graph"
    graph::G
    "length of the time horizon in discrete time steps"
    time_horizon_length::Int
end

function Base.show(io::IO, g::TimeSpaceGraph)
    return println(
        io,
        "Time-Space Graph with $(Graphs.nv(g.graph)) nodes and $(Graphs.ne(g.graph)) arcs",
    )
end

"""
$TYPEDSIGNATURES

Returns the range of time steps in the time space graph.
"""
function time_horizon(g::TimeSpaceGraph)
    return 1:(g.time_horizon_length)
end

"""
$TYPEDSIGNATURES

Adds a timed copy of the given network node for each time step in the time horizon.
"""
function add_network_node!(time_space_graph::TimeSpaceGraph, node::NetworkNode)
    for time_step in time_horizon(time_space_graph)
        Graphs.add_vertex!(time_space_graph.graph, (node.id, time_step), node)
    end
end

"""
$TYPEDSIGNATURES
"""
function add_network_arc!(
    time_space_graph::TimeSpaceGraph,
    origin::NetworkNode,
    destination::NetworkNode,
    arc::NetworkArc;
    wrap_time::Bool,
)
    (; time_horizon_length) = time_space_graph
    for t in time_horizon(time_space_graph)
        u_t = (origin.id, t)
        destination_time = t + arc.travel_time_steps

        # Handle time wrapping if enabled
        if destination_time > time_horizon_length
            if wrap_time
                destination_time -= time_horizon_length
            else
                break
            end
        end

        v_t = (destination.id, destination_time)
        was_added = Graphs.add_edge!(time_space_graph.graph, u_t, v_t, arc)
        if !was_added
            throw(
                ErrorException("Unable to add edge from $u_t to $v_t to time-space graph")
            )
        end
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Constructor for `TimeSpaceGraph`.
Creates timed copies of all nodes and arcs from the `network_graph` for each step in `1:time_horizon_length`.
"""
function TimeSpaceGraph(
    network_graph::NetworkGraph, time_horizon_length::Int; wrap_time::Bool
)
    # Initialize empty TimeSpaceGraph
    graph = MetaGraph(
        Graphs.DiGraph();
        label_type=Tuple{String,Int},
        vertex_data_type=NetworkNode,
        edge_data_type=NetworkArc,
    )
    time_space_graph = TimeSpaceGraph(graph, time_horizon_length)

    # Fill with timed copies of network nodes
    for node_id in MetaGraphsNext.labels(network_graph.graph)
        node = network_graph.graph[node_id]
        add_network_node!(time_space_graph, node)

        # NOTE: wait arcs (t -> t+1) are intentionally not added here to keep
        # the time-space graph representation focused on network movement arcs
        # (movement wrapping is still handled when adding network arcs).
    end

    # Connect timed nodes according to network arcs
    for (u_id, v_id) in MetaGraphsNext.edge_labels(network_graph.graph)
        u = network_graph.graph[u_id]
        v = network_graph.graph[v_id]
        arc = network_graph.graph[u_id, v_id]
        add_network_arc!(time_space_graph, u, v, arc; wrap_time=wrap_time)
    end

    return time_space_graph
end
