"""
$TYPEDEF

A solution to the network design optimization problem.
It stores the chosen paths for each bundle in the `TravelTimeGraph` and precomputes
key metrics such as commodity distributions on arcs and individual arc costs.

# Fields
$TYPEDFIELDS
"""
struct Solution{C<:LightCommodity}
    "Paths for each bundle in the instance. `bundle_paths[i]` is a sequence of node codes in the `TravelTimeGraph` for the i-th bundle."
    bundle_paths::Vector{Vector{Int}}
    "Commodities on each arc of the `TimeSpaceGraph`. Maps `(u, v)` to a list of commodities."
    commodities_on_arcs::Dict{Tuple{Int,Int},Vector{C}}
    "Bin assignments on each arc (for `BinPackingArcCost` arcs). Maps `(u, v)` to a list of bins."
    bin_assignments::Dict{Tuple{Int,Int},Vector{Bin{C}}}
    "Cost of each arc in the solution. Maps `(u, v)` to the arc's cost."
    arc_costs::Dict{Tuple{Int,Int},Float64}
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

Construct a `Solution` from bundle paths and an instance.
This constructor precomputes commodity distributions on arcs, bin-packing results, and total cost.
"""
function Solution(
    bundle_paths::Vector{Vector{Int}}, instance::Instance{Bundle{Order{IDA,I}}}
) where {IDA,I}
    (; time_space_graph, bundles) = instance

    C = LightCommodity{IDA,I}
    # Project paths to TimeSpaceGraph and collect commodities per arc
    commodities_on_arcs = Dict{Tuple{Int,Int},Vector{C}}()

    for (bundle_idx, ttg_path) in enumerate(bundle_paths)
        bundle = bundles[bundle_idx]

        # For each order in the bundle, project the path and collect commodities
        for order in bundle.orders
            tsg_path = [
                project_to_time_space_graph(node_code, order, instance) for
                node_code in ttg_path
            ]

            # Add all commodities from this order to each arc in the path
            for i in 1:(length(tsg_path) - 1)
                u, v = tsg_path[i], tsg_path[i + 1]
                edge = (u, v)

                if !haskey(commodities_on_arcs, edge)
                    commodities_on_arcs[edge] = C[]
                end

                append!(commodities_on_arcs[edge], order.commodities)
            end
        end
    end

    # Compute cost and bin-packing results
    bin_assignments = Dict{Tuple{Int,Int},Vector{Bin{C}}}()
    arc_costs = Dict{Tuple{Int,Int},Float64}()

    for (edge, commodities) in commodities_on_arcs
        u, v = edge

        # Convert codes to labels for MetaGraphsNext
        u_label = MetaGraphsNext.label_for(time_space_graph.graph, u)
        v_label = MetaGraphsNext.label_for(time_space_graph.graph, v)

        # Get the arc metadata from the TimeSpaceGraph
        if !haskey(time_space_graph.graph, u_label, v_label)
            @warn "Arc ($u_label, $v_label) not found in TimeSpaceGraph"
            continue
        end

        arc = time_space_graph.graph[u_label, v_label]

        # Handle BinPackingArcCost specially to avoid double computation
        if arc.cost isa BinPackingArcCost
            assignments = compute_bin_assignments(arc.cost, commodities)
            bin_assignments[edge] = assignments
            arc_costs[edge] = arc.cost.cost_per_bin * length(assignments)
        else
            # Evaluate cost using the arc's cost function
            arc_costs[edge] = evaluate(arc.cost, commodities)
        end
    end

    return Solution{C}(bundle_paths, commodities_on_arcs, bin_assignments, arc_costs)
end

"""
$TYPEDSIGNATURES

Compute the cost of the solution.
Sums the individual arc costs stored in the solution.
"""
function cost(sol::Solution)
    return sum(values(sol.arc_costs); init=0.0)
end

"""
$TYPEDSIGNATURES

Compute the cost of the solution (legacy signature for compatibility).
"""
function cost(sol::Solution, instance::Instance)
    return sum(values(sol.arc_costs); init=0.0)
end
