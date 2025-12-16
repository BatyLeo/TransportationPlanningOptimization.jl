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
        "TimeSpaceGraph with $(Graphs.nv(g.graph)) nodes and $(Graphs.ne(g.graph)) arcs over a time horizon of length $(g.time_horizon_length)",
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
    arc::NetworkArc,
)
    for t in time_horizon(time_space_graph)
        u_t = (origin.id, t)
        v_t = (destination.id, t + arc.travel_time) # TODO: make sure evrything is correct and see if anything else is needed
        Graphs.add_edge!(time_space_graph.graph, u_t, v_t, arc)
    end
    return nothing
end

function TimeSpaceGraph(network_graph::NetworkGraph, time_horizon_length::Int)
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
        add_network_node!(TimeSpaceGraph(graph, time_horizon_length), node)
    end

    # Connect timed nodes according to network arcs
    for (u_id, v_id) in MetaGraphsNext.edge_labels(network_graph.graph)
        u = network_graph.graph[u_id]
        v = network_graph.graph[v_id]
        arc = network_graph.graph[u_id, v_id]
        add_network_arc!(time_space_graph, u, v, arc)
    end

    return time_space_graph
end
