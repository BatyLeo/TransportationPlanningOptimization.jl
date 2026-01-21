"""
$TYPEDEF

An `Instance` represents a transportation planning problem instance, containing bundles of orders, a network graph, and a time horizon.

# Fields
$TYPEDFIELDS
"""
@kwdef struct Instance{B<:Bundle,G<:NetworkGraph,TSG<:TimeSpaceGraph,TTG<:TravelTimeGraph}
    "list of bundles in the instance"
    bundles::Vector{B}
    "underlying network graph"
    network_graph::G
    "length of the time horizon in discrete time steps"
    time_horizon_length::Int
    "discretization time step for the instance"
    time_step::Period
    "mapping from time step index to date"
    time_step_to_date::Vector{Dates.Date}
    "time expanded graph (for order paths)"
    time_space_graph::TSG
    "travel time graph (for bundle paths)"
    travel_time_graph::TTG
end

"""
$TYPEDSIGNATURES

Return the number of bundles in the instance.
"""
function bundle_count(instance::Instance)
    return length(instance.bundles)
end

"""
$TYPEDSIGNATURES

Return the number of orders in the instance.
"""
function order_count(instance::Instance)
    return sum(length(bundle.orders) for bundle in instance.bundles)
end

"""
$TYPEDSIGNATURES

Return the number of commodities in the instance.
"""
function commodity_count(instance::Instance)
    return sum(
        length(order.commodities) for bundle in instance.bundles for order in bundle.orders
    )
end

"""
$TYPEDSIGNATURES

Return a summary of the instance.
"""
function Base.show(io::IO, instance::Instance)
    nb_orders = order_count(instance)
    nb_commodities = commodity_count(instance)
    padding = length(string(nb_commodities))
    println(io, "Instance Summary:")
    println(
        io,
        "  • Horizon: $(lpad(string(instance.time_horizon_length) * " time steps", 0)) ($(instance.time_step) per step)",
    )
    println(io, "  • Commodities: $(lpad(nb_commodities, padding))")
    println(io, "  • Orders:      $(lpad(nb_orders, padding))")
    println(io, "  • Bundles:     $(lpad(bundle_count(instance), padding))")
    print(io, "  • ", instance.network_graph)
    print(io, "  • ", instance.time_space_graph)
    print(io, "  • ", instance.travel_time_graph)
    return nothing
end

"""
$TYPEDSIGNATURES

Return the time horizon of the instance as a range of discrete time steps.
"""
function time_horizon(instance::Instance)
    return 1:(instance.time_horizon_length)
end

# By default, group by origin and destination IDs
function _default_group_by(commodity::Commodity)
    return nothing
end

"""
$TYPEDSIGNATURES

Validate that a bundle can reach its destination from its origin while respecting forbidden constraints.

Uses BFS to check reachability in the TravelTimeGraph, avoiding forbidden nodes and arcs.
Explores all edges in the time-expanded graph to check if ANY feasible path exists.
Returns `true` if the bundle is feasible, `false` otherwise.
"""
function validate_bundle_feasibility(ttg::TravelTimeGraph, bundle_idx::Int, bundle::Bundle)
    origin_code = ttg.origin_codes[bundle_idx]
    destination_code = ttg.destination_codes[bundle_idx]

    # BFS to check reachability
    visited = Set{Int}()
    queue = Int[origin_code]
    push!(visited, origin_code)

    while !isempty(queue)
        current_code = popfirst!(queue)

        # Check if we reached the destination
        if current_code == destination_code
            return true
        end

        # Get current node information
        current_label = MetaGraphsNext.label_for(ttg.graph, current_code)
        current_node_id = current_label[1]

        # Explore all outgoing edges in the underlying graph
        for neighbor_code in Graphs.outneighbors(ttg.graph.graph, current_code)
            # Skip if already visited
            if neighbor_code in visited
                continue
            end

            # Get neighbor node information
            neighbor_label = MetaGraphsNext.label_for(ttg.graph, neighbor_code)
            neighbor_node_id = neighbor_label[1]

            # Check forbidden constraints
            arc_forbidden = (
                (current_node_id, neighbor_node_id) in bundle.forbidden_arcs ||
                current_node_id in bundle.forbidden_nodes ||
                neighbor_node_id in bundle.forbidden_nodes
            )

            if !arc_forbidden
                push!(visited, neighbor_code)
                push!(queue, neighbor_code)
            end
        end
    end

    # Destination not reachable
    return false
end

function _compute_start_date(
    commodities::Vector{Commodity{is_date_arrival,ID,I}}, wrap_time::Bool
) where {is_date_arrival,ID,I}
    if is_date_arrival
        # Arrival-based: start date is min of arrival dates (- max delivery times)
        return if wrap_time
            minimum(Dates.Date(c.date) for c in commodities)
        else
            # Need to extend the time horizon to account for max delivery times, if no wrapping
            minimum(Dates.Date(c.date - c.max_delivery_time) for c in commodities)
        end
    else
        # Departure-based: start date is min of departure dates
        return minimum(Dates.Date(c.date) for c in commodities)
    end
end

"""
$TYPEDSIGNATURES

Build an `Instance` from normalized inputs.

This function expects `nodes` and `arcs` already in `NetworkGraph` form (i.e., `arcs` are tuples `(origin_id, destination_id, NetworkArc)`), and `commodities` are user-facing `Commodity` objects. In brief, it:

- Determines the instance start date (arrival- or departure-based) and converts dates into discrete time step indices using `period_steps`.
- Expands each `Commodity` into `LightCommodity` items and groups them into `Order`s (by time step, origin, destination and `group_by`) and `Bundle`s (by origin, destination and group).
- Computes `time_horizon_length` (accounting for `max_delivery_time` unless `wrap_time=true`), constructs `TimeSpaceGraph` and `TravelTimeGraph`, and returns a populated `Instance`.

Arguments:
- `nodes::Vector{<:NetworkNode}`
- `arcs::Vector{<:Tuple{String,String,<:NetworkArc}}`
- `commodities::Vector{Commodity}`
- `time_step::Period`

Keywords:
- `group_by` (default: `_default_group_by`): function grouping commodities into orders
- `wrap_time` (default: false): whether the time horizon wraps (cyclic)
- `check_bundle_feasibility` (default: true): whether to validate that bundles have feasible paths after applying forbidden constraints

See also: the `Instance` constructor which accepts `Arc` inputs and performs automatic cost-type inference.
"""
function build_instance(
    nodes::Vector{<:NetworkNode},
    arcs::Vector{<:Tuple{String,String,<:NetworkArc}},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period;
    group_by=_default_group_by,
    wrap_time=false,
    check_bundle_feasibility=true,
) where {is_date_arrival,ID,I}
    # Building the network graph (arcs are provided as (origin_id,destination_id,NetworkArc))
    network_graph = NetworkGraph(nodes, arcs)

    # Wrapping commodities into light commodities
    full_commodities = LightCommodity{is_date_arrival,I}[]
    # Key is (time_step_idx, origin_id, destination_id), value is (vector of LightCommodity, min_time_steps)
    first_key = (
        1, commodities[1].origin_id, commodities[1].destination_id, group_by(commodities[1])
    )
    order_dict = Dict{
        typeof(first_key),Tuple{Vector{LightCommodity{is_date_arrival,I}},Int}
    }()

    start_date = _compute_start_date(commodities, wrap_time)

    for commodity in commodities
        to_append = [
            LightCommodity(;
                origin_id=commodity.origin_id,
                destination_id=commodity.destination_id,
                size=commodity.size,
                info=commodity.info,
                is_date_arrival=is_date_arrival,
            ) for _ in 1:(commodity.quantity)
        ]
        max_transit_steps = period_steps(
            commodity.max_delivery_time, time_step; roundup=floor
        )
        append!(full_commodities, to_append)
        # time_step_idx relative to the earliest arrival_date (discretized by time_step)
        time_step_idx =
            period_steps(
                Dates.Date(commodity.date) - start_date, time_step; roundup=floor
            ) + 1
        key = (
            time_step_idx,
            commodity.origin_id,
            commodity.destination_id,
            group_by(commodity),
        )

        if haskey(order_dict, key)
            commodities_list, min_steps = order_dict[key]
            append!(commodities_list, to_append)
            order_dict[key] = (commodities_list, min(min_steps, max_transit_steps))
        else
            order_dict[key] = (to_append, max_transit_steps)
        end
    end

    if is_date_arrival
        time_horizon_length = maximum(key[1] for key in keys(order_dict))
    else
        time_horizon_length = if wrap_time
            maximum(key[1] for key in keys(order_dict))
        else
            maximum(key[1] + order_dict[key][2] for key in keys(order_dict))
        end
    end

    # Build orders and bundles simultaneously in one pass
    first_group_key = (
        commodities[1].origin_id, commodities[1].destination_id, group_by(commodities[1])
    )
    bundle_dict = Dict{
        Tuple{String,String,eltype(first_group_key)},Vector{Order{is_date_arrival,I}}
    }()
    # Track forbidden constraints per bundle as we process commodities
    bundle_forbidden_dict = Dict{
        Tuple{String,String,eltype(first_group_key)},
        Tuple{Set{String},Set{Tuple{String,String}}},
    }()
    orders = Order{is_date_arrival,I}[]

    for key in keys(order_dict)
        time_step_idx, origin_id, destination_id, group_key = key
        commodities_list, min_steps = order_dict[key]
        min_steps = min(time_horizon_length, min_steps)
        order = Order{is_date_arrival,I}(commodities_list, time_step_idx, min_steps)
        push!(orders, order)

        bundle_key = (origin_id, destination_id, group_key)
        if haskey(bundle_dict, bundle_key)
            push!(bundle_dict[bundle_key], order)
        else
            bundle_dict[bundle_key] = [order]
        end
    end

    # Aggregate forbidden constraints from commodities (already processed earlier)
    for commodity in commodities
        bundle_key = (commodity.origin_id, commodity.destination_id, group_by(commodity))
        if haskey(bundle_forbidden_dict, bundle_key)
            forbidden_nodes, forbidden_arcs = bundle_forbidden_dict[bundle_key]
            union!(forbidden_nodes, commodity.forbidden_node_ids)
            union!(forbidden_arcs, commodity.forbidden_arcs)
        else
            forbidden_nodes = Set{String}(commodity.forbidden_node_ids)
            forbidden_arcs = Set{Tuple{String,String}}(commodity.forbidden_arcs)
            bundle_forbidden_dict[bundle_key] = (forbidden_nodes, forbidden_arcs)
        end
    end

    # Create bundles with aggregated forbidden constraints
    bundles = Bundle{Order{is_date_arrival,I}}[]
    for key in keys(bundle_dict)
        origin_id, destination_id, _ = key
        forbidden_nodes, forbidden_arcs = get(
            bundle_forbidden_dict, key, (Set{String}(), Set{Tuple{String,String}}())
        )

        # Validate that bundle doesn't forbid its own origin or destination
        if origin_id in forbidden_nodes
            throw(
                ArgumentError(
                    "Bundle ($origin_id → $destination_id) has forbidden node at its origin. " *
                    "Commodities cannot forbid their own origin node.",
                ),
            )
        end
        if destination_id in forbidden_nodes
            throw(
                ArgumentError(
                    "Bundle ($origin_id → $destination_id) has forbidden node at its destination. " *
                    "Commodities cannot forbid their own destination node.",
                ),
            )
        end

        bundle = Bundle(
            bundle_dict[key], origin_id, destination_id, forbidden_nodes, forbidden_arcs
        )
        push!(bundles, bundle)
    end

    # Build mapping from time step index to date
    time_step_to_date = [start_date + (i - 1) * time_step for i in 1:time_horizon_length]

    time_space_graph = TimeSpaceGraph(
        network_graph, time_horizon_length; wrap_time=wrap_time
    )
    travel_time_graph = TravelTimeGraph(network_graph, bundles)

    # Validate bundle feasibility if requested
    if check_bundle_feasibility
        infeasible_bundles = Tuple{Int,String,String}[]
        for (bundle_idx, bundle) in enumerate(bundles)
            if !validate_bundle_feasibility(travel_time_graph, bundle_idx, bundle)
                push!(
                    infeasible_bundles,
                    (bundle_idx, bundle.origin_id, bundle.destination_id),
                )
            end
        end

        if !isempty(infeasible_bundles)
            error_msg = "Found $(length(infeasible_bundles)) infeasible bundle(s) with no path from origin to destination"
            # Check if any have forbidden constraints
            has_forbidden = any(
                !isempty(bundles[idx].forbidden_nodes) ||
                !isempty(bundles[idx].forbidden_arcs) for (idx, _, _) in infeasible_bundles
            )
            if has_forbidden
                error_msg *= " after applying forbidden constraints"
            else
                error_msg *= " (network may be ill-defined)"
            end
            error_msg *= ":\n"
            for (idx, origin, dest) in infeasible_bundles
                error_msg *= "  • Bundle $idx: $origin → $dest\n"
            end
            if has_forbidden
                error_msg *= "Consider relaxing forbidden node/arc constraints for these bundles."
            end
            throw(ArgumentError(error_msg))
        end
    end

    return Instance(;
        time_horizon_length,
        time_step,
        time_step_to_date,
        bundles,
        network_graph,
        time_space_graph,
        travel_time_graph,
    )
end

"""
$TYPEDSIGNATURES

Infer the cost types present in a vector of arcs by scanning their actual cost function types.
Returns a tuple of unique cost types found in the arcs.

This is a runtime operation that enables automatic cost type detection, but the result
can be passed to type-stable inner functions via function barriers.
"""
function infer_cost_types(arcs::Vector{<:Arc})
    if isempty(arcs)
        return ()
    end
    # Collect unique cost types
    types = unique(typeof(arc.cost) for arc in arcs)
    return Tuple(types)
end

"""
$TYPEDSIGNATURES

Build an `Instance` from `raw_arcs::Vector{<:Arc}` with explicit `arc_cost_types` for type stability.

This variant converts `raw_arcs` into `NetworkArc`s using `collect_arcs(arc_cost_types, raw_arcs, time_step)` and then delegates to `build_instance(nodes, arcs, commodities, time_step; group_by, wrap_time)`.
"""
function build_instance(
    nodes::Vector{<:NetworkNode},
    raw_arcs::Vector{<:Arc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period,
    arc_cost_types::Tuple;
    group_by=_default_group_by,
    wrap_time=false,
    check_bundle_feasibility=true,
) where {is_date_arrival,ID,I}
    arcs = collect_arcs(arc_cost_types, raw_arcs, time_step)
    return build_instance(
        nodes,
        arcs,
        commodities,
        time_step;
        group_by=group_by,
        wrap_time=wrap_time,
        check_bundle_feasibility=check_bundle_feasibility,
    )
end

"""
    Instance(
        nodes::Vector{<:NetworkNode},
        arcs::Vector{<:Arc},
        commodities::Vector{Commodity{is_date_arrival,ID,I}},
        time_step::Period;
        group_by=_default_group_by,
        wrap_time=false,
    ) where {is_date_arrival,ID,I}

Construct an `Instance` from high-level `Arc` inputs by automatically inferring cost function types.

# Arguments
- `nodes::Vector{<:NetworkNode}`: List of nodes in the spatial network.
- `arcs::Vector{<:Tuple{String,String,<:NetworkArc}}`: Arcs in the spatial network as `(origin_id, destination_id, arc_data)`.
- `commodities::Vector{Commodity}`: User-facing commodity specifications.
- `time_step::Period`: The discrete time step size (e.g., `Hour(1)`, `Day(1)`).

Keywords:
- `group_by` (default: `_default_group_by`): Optional function to group commodities into `Order`s (default: no additional grouping).
- `wrap_time` (default: false): whether the time horizon should wrap (cyclic)
- `check_bundle_feasibility` (default: true): whether to validate that bundles have feasible paths after applying forbidden constraints

# Discretization and Normalization
1. **Start Date**: The time horizon starts at the earliest release date (for departure-based) or the earliest possible start (for arrival-based).
2. **Time Steps**: Dates and periods are converted to discrete steps using `period_steps`.
3. **Consolidation**: Commodities with the same origin, destination, and delivery step are grouped into `Order`s. Orders with the same origin and destination are grouped into `Bundle`s for routing.
4. **Graphs**: Both `TimeSpaceGraph` (absolute time) and `TravelTimeGraph` (relative time) are constructed.
"""
function Instance(
    nodes::Vector{<:NetworkNode},
    raw_arcs::Vector{<:Arc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period;
    group_by=_default_group_by,
    wrap_time=false,
    check_bundle_feasibility=true,
) where {is_date_arrival,ID,I}
    # Infer cost types from the arcs
    cost_types = infer_cost_types(raw_arcs)
    # Delegate to the type-stable version
    return build_instance(
        nodes,
        raw_arcs,
        commodities,
        time_step,
        cost_types;
        group_by,
        wrap_time,
        check_bundle_feasibility,
    )
end
