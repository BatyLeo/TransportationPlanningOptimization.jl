"""
    incremental_cost(arc_f::AbstractArcCostFunction, existing_commodities, new_commodities)

Compute the additional cost of adding `new_commodities` to an arc that already contains `existing_commodities`.
"""
function incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    # Default implementation: evaluate total and subtract
    all_commodities = vcat(existing_commodities, new_commodities)
    return evaluate(arc_f, all_commodities) - evaluate(arc_f, existing_commodities)
end

# Specialized for LinearArcCost for efficiency
function incremental_cost(
    arc_f::LinearArcCost, existing_commodities::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    total_new_size = sum(c.size for c in new_commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_new_size
end

"""
    compute_ttg_edge_incremental_cost(sol, instance, bundle, u_ttg_label, v_ttg_label)

Compute the incremental cost of a TravelTimeGraph edge for a specific bundle,
considering all its orders and their projections to the TimeSpaceGraph.
"""
function compute_ttg_edge_incremental_cost(
    sol::Solution{C}, instance::Instance, bundle::Bundle, u_ttg_code, v_ttg_code
) where {C}
    tsg = instance.time_space_graph

    # IF it's a shortcut arc, return zero cost
    u_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)
    v_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code)
    if u_ttg_label[1] == v_ttg_label[1]
        return 0.0
    end

    # Collect all TSG edges affected by this TTG edge for this bundle
    # Many orders might map to the same TSG edge
    tsg_edge_to_new_commodities = Dict{Tuple{Int,Int},Vector{C}}()

    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        edge = (u_tsg, v_tsg)

        if !haskey(tsg_edge_to_new_commodities, edge)
            tsg_edge_to_new_commodities[edge] = C[]
        end
        append!(tsg_edge_to_new_commodities[edge], order.commodities)
    end

    total_incremental_cost = 0.0

    for (edge, new_comms) in tsg_edge_to_new_commodities
        u_tsg, v_tsg = edge
        u_tsg_label = MetaGraphsNext.label_for(tsg.graph, u_tsg)
        v_tsg_label = MetaGraphsNext.label_for(tsg.graph, v_tsg)

        if !MetaGraphsNext.haskey(tsg.graph, u_tsg_label, v_tsg_label)
            @warn "TSG edge ($u_tsg_label -> $v_tsg_label) does not exist!"
            return Inf # Infeasible for this bundle
        end

        arc = tsg.graph[u_tsg_label, v_tsg_label]
        existing_comms = get(sol.commodities_on_arcs, edge, C[])

        inc = incremental_cost(arc.cost, existing_comms, new_comms)
        total_incremental_cost += inc
    end

    return total_incremental_cost
end

"""
    insert_bundle!(sol, instance, bundle_idx)

Find the cheapest path for a bundle in the TravelTimeGraph (considering incremental costs)
and add it to the solution.
"""
function insert_bundle!(sol::Solution, instance::Instance, bundle_idx::Int)
    ttg = instance.travel_time_graph
    bundle = instance.bundles[bundle_idx]

    for (u_code, v_code) in ttg.bundle_arcs[bundle_idx]
        ttg.cost_matrix[u_code, v_code] = compute_ttg_edge_incremental_cost(
            sol, instance, bundle, u_code, v_code
        )
    end

    origin = ttg.origin_codes[bundle_idx]
    destination = ttg.destination_codes[bundle_idx]

    res = Graphs.dijkstra_shortest_paths(ttg.graph, origin, ttg.cost_matrix)
    path = Graphs.enumerate_paths(res, destination)

    if isempty(path)
        throw(ArgumentError("No feasible path found for bundle $bundle_idx, ($path)"))
    end

    add_bundle_path!(sol, instance, bundle_idx, path)
    return nothing
end

"""
    greedy_construction(instance)

Construct a solution by inserting bundles one by one into an initially empty solution.
Bundles are processed in the order they appear in the instance.
"""
function greedy_construction(instance::Instance)
    sol = Solution(instance)
    # Get bundle indices sorted by decreasing total size
    sorted_indices = sortperm(instance.bundles; by=total_size, rev=true)
    for e in Graphs.edges(instance.travel_time_graph.graph)
        u, v = Graphs.src(e), Graphs.dst(e)
        println(
            "Arc ($u, $v): ",
            label_for(instance.travel_time_graph.graph, u),
            " -> ",
            label_for(instance.travel_time_graph.graph, v),
            " Cost: ",
            instance.travel_time_graph.cost_matrix[u, v],
        )
    end
    display(instance.travel_time_graph.cost_matrix)
    @showprogress for i in sorted_indices
        insert_bundle!(sol, instance, i)
        println("Inserting bundle $i ($(instance.bundles[i]))")
        for e in Graphs.edges(instance.travel_time_graph.graph)
            u, v = Graphs.src(e), Graphs.dst(e)
            println(
                "Arc ($u, $v): ",
                label_for(instance.travel_time_graph.graph, u),
                " -> ",
                label_for(instance.travel_time_graph.graph, v),
                " Cost: ",
                instance.travel_time_graph.cost_matrix[u, v],
            )
        end
        display(instance.travel_time_graph.cost_matrix)
        println("Bundle inserted with path: $(sol.bundle_paths[i])")
        println("Current cost: $(cost(sol, instance))")
        println("-----")
    end
    return sol
end
