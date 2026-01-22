"""
$TYPEDEF

A time-expanded graph where nodes represent `(location, τ)`. 
The parameter `is_date_arrival` (boolean) defines the semantics of `τ`:

- **`is_date_arrival = true` (Count Down / Remaining Time)**:
    `τ` represents the remaining time budget to meet a deadline.
    - Arcs move from `τ` to `τ - travel_time`.
    - Paths enter the graph at `(origin, max_duration)` and exit at `(destination, 0)`.
- **`is_date_arrival = false` (Count Up / Elapsed Time)**:
    `τ` represents the time elapsed since a release date.
    - Arcs move from `τ` to `τ + travel_time`.
    - Paths enter the graph at `(origin, 0)` and exit at `(destination, max_duration)`.

# Fields
$TYPEDFIELDS
"""
struct TravelTimeGraph{is_date_arrival,G<:MetaGraph}
    "underlying time-expanded graph"
    graph::G
    "Maximum duration allowed for a bundle in this graph"
    max_time_steps::Int
    "Cost matrix between timed nodes (sparse)"
    cost_matrix::SparseMatrixCSC{Float64,Int}
    "Map from bundle index to unique origin node code entry point"
    origin_codes::Vector{Int}
    "Map from bundle index to unique destination node code exit point"
    destination_codes::Vector{Int}
    "arcs usable for each bundle to ease looping through them"
    bundle_arcs::Vector{Vector{Tuple{Int,Int}}}
end

function Base.show(io::IO, g::TravelTimeGraph{is_date_arrival}) where {is_date_arrival}
    return println(
        io,
        "Travel-Time Graph with $(Graphs.nv(g.graph)) nodes and $(Graphs.ne(g.graph)) arcs",
    )
end

function is_date_arrival(::TravelTimeGraph{IDA}) where {IDA}
    return IDA
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
    is_date_arrival::Bool,
) where {B<:Bundle}
    if node.node_type == :origin
        if is_date_arrival
            # Max duration over all bundles starting at this node
            max_duration = maximum(
                order.max_transit_steps for bundle in get(node_to_bundles_map, node.id, [])
                for order in bundle.orders;
                init=-1,
            )
            for τ in 0:max_duration
                Graphs.add_vertex!(g, (node.id, τ), node)
            end

            for τ in 1:max_duration
                # If remaining time: spend budget, move from τ to τ-1
                u, v = (node.id, τ), (node.id, τ - 1)
                if haskey(g, u) && haskey(g, v)
                    Graphs.add_edge!(g, u, v, SHORTCUT_ARC)
                end
            end
        else
            # Elapsed time: origin only appears in first step (tau=0)
            Graphs.add_vertex!(g, (node.id, 0), node)
        end
    elseif node.node_type == :destination
        if is_date_arrival
            # Remaining time: destination only appears in last step (tau=0)
            Graphs.add_vertex!(g, (node.id, 0), node)
        else
            # Elapsed time: copies for all time steps up to max_time_steps
            for τ in 0:max_time_steps
                Graphs.add_vertex!(g, (node.id, τ), node)
            end
            # Shortcuts to stay at destination (increasing τ)
            for τ in 1:max_time_steps
                u, v = (node.id, τ - 1), (node.id, τ)
                if haskey(g, u) && haskey(g, v)
                    Graphs.add_edge!(g, u, v, SHORTCUT_ARC)
                end
            end
        end
    else
        # Intermediate nodes: timed copies for all steps
        for τ in 0:max_time_steps
            Graphs.add_vertex!(g, (node.id, τ), node)
        end
        # # Shortcuts (wait arcs), no wait arcs for now
        # for τ in 1:max_time_steps
        #     if is_date_arrival
        #         u, v = (node.id, τ), (node.id, τ - 1)
        #     else
        #         u, v = (node.id, τ - 1), (node.id, τ)
        #     end
        #     if haskey(g, u) && haskey(g, v)
        #         Graphs.add_edge!(g, u, v, SHORTCUT_ARC)
        #     end
        # end
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
    is_date_arrival::Bool,
)
    for τ_u in 0:max_time_steps
        u = (origin.id, τ_u)
        d = travel_time_steps(arc)
        if is_date_arrival
            τ_v = τ_u - d
        else
            τ_v = τ_u + d
        end
        v = (destination.id, τ_v)
        if haskey(g, u) && haskey(g, v)
            Graphs.add_edge!(g, u, v, arc)
        end
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Compute usable arcs for each bundle by finding all arcs that lie on paths
from the bundle's origin to its destination in the travel-time graph.
"""
function _compute_bundle_arcs(
    graph::MetaGraph, origin_codes::Vector{Int}, destination_codes::Vector{Int}
)
    bundle_arcs = Vector{Vector{Tuple{Int,Int}}}(undef, length(origin_codes))

    for i in eachindex(origin_codes)
        origin_code = origin_codes[i]
        destination_code = destination_codes[i]

        # Find all nodes reachable from origin
        reachable_from_origin = Set{Int}()
        queue = [origin_code]
        push!(reachable_from_origin, origin_code)
        while !isempty(queue)
            node = popfirst!(queue)
            for neighbor in Graphs.outneighbors(graph, node)
                if neighbor ∉ reachable_from_origin
                    push!(reachable_from_origin, neighbor)
                    push!(queue, neighbor)
                end
            end
        end

        # Find all nodes that can reach destination (reverse BFS)
        can_reach_destination = Set{Int}()
        queue = [destination_code]
        push!(can_reach_destination, destination_code)
        while !isempty(queue)
            node = popfirst!(queue)
            for neighbor in Graphs.inneighbors(graph, node)
                if neighbor ∉ can_reach_destination
                    push!(can_reach_destination, neighbor)
                    push!(queue, neighbor)
                end
            end
        end

        # Intersection: nodes on paths from origin to destination
        nodes_on_paths = intersect(reachable_from_origin, can_reach_destination)

        # Collect all arcs where both endpoints are on paths
        # Pre-allocate to reduce allocations
        arcs = Tuple{Int,Int}[]
        sizehint!(arcs, length(nodes_on_paths) * 3)  # Estimate avg out-degree
        for u in nodes_on_paths
            for v in Graphs.outneighbors(graph, u)
                if v in nodes_on_paths
                    push!(arcs, (u, v))
                end
            end
        end

        bundle_arcs[i] = arcs
    end

    return bundle_arcs
end

"""
$TYPEDSIGNATURES

Construct a `TravelTimeGraph` from a `NetworkGraph` and a set of `Bundle`s.
"""
function TravelTimeGraph(
    network_graph::NetworkGraph, bundles::Vector{<:Bundle{<:Order{is_date_arrival,I}}}
) where {is_date_arrival,I}
    # Initialize empty TimeTravelGraph
    graph = MetaGraph(
        Graphs.DiGraph();
        label_type=Tuple{String,Int},
        vertex_data_type=NetworkNode,
        edge_data_type=NetworkArc,
        default_weight=Inf,
    )

    isempty(bundles) && throw(ArgumentError("bundles cannot be empty"))

    max_time_steps = maximum(
        order.max_transit_steps for bundle in bundles for order in bundle.orders
    )

    node_to_bundles_map = compute_node_to_bundles_map(bundles)

    # Fill with timed copies of network nodes
    for node_id in MetaGraphsNext.labels(network_graph.graph)
        node = network_graph.graph[node_id]
        _add_network_node_to_travel_time_graph!(
            graph, node, node_to_bundles_map, max_time_steps, is_date_arrival
        )
    end

    # Connect timed nodes according to network arcs
    for (u_id, v_id) in MetaGraphsNext.edge_labels(network_graph.graph)
        u = network_graph.graph[u_id]
        v = network_graph.graph[v_id]
        arc = network_graph.graph[u_id, v_id]
        _add_network_arc_to_travel_time_graph!(
            graph, u, v, arc, max_time_steps, is_date_arrival
        )
    end

    # Build cost matrix
    n = Graphs.nv(graph)
    I_indices = Int[]
    J_indices = Int[]
    V_values = Float64[]
    for (u_id, v_id) in MetaGraphsNext.edge_labels(graph)
        i = MetaGraphsNext.code_for(graph, u_id)
        j = MetaGraphsNext.code_for(graph, v_id)
        push!(I_indices, i)
        push!(J_indices, j)
        push!(V_values, 0.0)
    end
    cost_matrix = sparse(I_indices, J_indices, V_values, n, n)

    origin_codes = Vector{Int}(undef, length(bundles))
    destination_codes = Vector{Int}(undef, length(bundles))

    for (i, bundle) in enumerate(bundles)
        max_val = maximum(order.max_transit_steps for order in bundle.orders)
        if is_date_arrival
            start_label = (bundle.origin_id, max_val)
            end_label = (bundle.destination_id, 0)
        else
            start_label = (bundle.origin_id, 0)
            end_label = (bundle.destination_id, max_val)
        end
        origin_codes[i] = MetaGraphsNext.code_for(graph, start_label)
        destination_codes[i] = MetaGraphsNext.code_for(graph, end_label)
    end

    # Compute usable arcs for each bundle
    bundle_arcs = _compute_bundle_arcs(graph, origin_codes, destination_codes)

    return TravelTimeGraph{is_date_arrival,typeof(graph)}(
        graph, max_time_steps, cost_matrix, origin_codes, destination_codes, bundle_arcs
    )
end
