"""
$TYPEDEF

A solution to the network design optimization problem.
It stores the chosen paths for each bundle in the `TravelTimeGraph`.

# Fields
$TYPEDFIELDS
"""
struct Solution
    "Paths for each bundle in the instance. `bundle_paths[i]` is a sequence of node codes in the `TravelTimeGraph` for the i-th bundle."
    bundle_paths::Vector{Vector{Int}}
end

"""
$TYPEDSIGNATURES

Check if a solution is feasible for a given instance.
Feasibility requires:
1. Every bundle in the instance must have a corresponding path in the solution.
2. Every path must exist (each arc exists in the graph).
3. Every path must start at the bundle's designated entry node (`origin_codes`).
4. Every path must end at the bundle's designated exit node (`destination_codes`).
"""
function is_feasible(sol::Solution, instance::Instance)
    (; travel_time_graph) = instance
    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        if isempty(path)
            return false
        end

        bundle = instance.bundles[bundle_idx]

        # Check connectivity
        for i in 1:(length(path) - 1)
            u, v = path[i], path[i + 1]
            if !Graphs.has_edge(travel_time_graph.graph, u, v)
                return false
            end
        end

        # Check start node
        start_node_code = path[1]
        valid_origin = travel_time_graph.origin_codes[bundle_idx]
        if start_node_code != valid_origin
            return false
        end

        # Check destination node
        end_node_code = path[end]
        valid_destination = travel_time_graph.destination_codes[bundle_idx]
        if end_node_code != valid_destination
            return false
        end
    end
    return true
end

"""
$TYPEDSIGNATURES

Project a node code from the `TravelTimeGraph` to a node code in the `TimeSpaceGraph` for a specific order.
The projection converts the graph-specific time `τ` (budget or elapsed) into absolute time `t` in the `TimeSpaceGraph`.

# Time Projection Formulas
- If `is_date_arrival = true`: `t = deadline - τ`
- If `is_date_arrival = false`: `t = release + τ`

Throws a `DomainError` if the resulting `t` is outside the instance time horizon `[1, time_horizon_length]`.
"""
function project_to_time_space_graph(
    ttg_node_code::Int, order::Order{is_date_arrival}, instance::Instance
) where {is_date_arrival}
    (; time_space_graph, travel_time_graph) = instance
    u_label, τ = MetaGraphsNext.label_for(travel_time_graph.graph, ttg_node_code)

    if is_date_arrival
        t = order.delivery_time_step - τ
    else
        t = order.delivery_time_step + τ
    end

    if !(1 <= t <= instance.time_horizon_length)
        throw(DomainError(t, "Projected time step out of bounds for order $(order)"))
    end

    tsg_node_label = (u_label, t)
    return MetaGraphsNext.code_for(time_space_graph.graph, tsg_node_label)
end

"""
$TYPEDSIGNATURES

Project bundle paths to order paths on the Time Space Graph.
Returns a Dict mapping Order to a Vector of TSG node codes (Int).
"""
function project_bundle_path_to_order_paths(sol::Solution, instance::Instance)
    order_paths = Dict{Order,Vector{Int}}()

    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        bundle = instance.bundles[bundle_idx]
        for order in bundle.orders
            tsg_path = [
                project_to_time_space_graph(node_code, order, instance) for
                node_code in path
            ]
            order_paths[order] = tsg_path
        end
    end
    return order_paths
end

"""
$TYPEDSIGNATURES

Compute the cost of the solution.
"""
function cost(sol::Solution, instance::Instance)
    # Project paths
    order_paths = project_bundle_path_to_order_paths(sol, instance)

    # Compute edge loads
    # Map (u, v) in TSG -> total size of commodities
    edge_loads = Dict{Tuple{Int,Int},Float64}()

    for (order, path) in order_paths
        if isempty(path)
            continue
        end
        total_size = sum(c.size for c in order.commodities)

        for i in 1:(length(path) - 1)
            u, v = path[i], path[i + 1]
            edge = (u, v)
            edge_loads[edge] = get(edge_loads, edge, 0.0) + total_size
        end
    end

    total_cost = 0.0
    # Note: this cost computation is a placeholder.
    # Bin packing need to be computed depending on the arc type and associated cost function.
    # There may also be other cost sources.
    for ((u, v), load) in edge_loads
        total_cost += load
    end

    return total_cost
end
