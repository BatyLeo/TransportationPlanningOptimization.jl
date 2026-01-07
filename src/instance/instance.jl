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

Build an `Instance` from raw problem data.

# Arguments
- `nodes::Vector{<:NetworkNode}`: List of nodes in the spatial network.
- `arcs::Vector{<:Tuple{String,String,<:NetworkArc}}`: Arcs in the spatial network as `(origin_id, destination_id, arc_data)`.
- `commodities::Vector{Commodity}`: User-facing commodity specifications.
- `time_step::Period`: The discrete time step size (e.g., `Hour(1)`, `Day(1)`).
- `group_by`: Optional function to group commodities into `Order`s (default: no additional grouping).

# Discretization and Normalization
1. **Start Date**: The time horizon starts at the earliest release date (for departure-based) or the earliest possible start (for arrival-based).
2. **Time Steps**: Dates and periods are converted to discrete steps using `period_steps`.
3. **Consolidation**: Commodities with the same origin, destination, and delivery step are grouped into `Order`s. Orders with the same origin and destination are grouped into `Bundle`s for routing.
4. **Graphs**: Both `TimeSpaceGraph` (absolute time) and `TravelTimeGraph` (relative time) are constructed.
"""
function build_instance(
    nodes::Vector{<:NetworkNode},
    arcs::Vector{<:Tuple{String,String,<:NetworkArc}},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period;
    group_by=_default_group_by,
    wrap_time=false,
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

    # normalize all dates to Date so DateTime operands are handled consistently
    if is_date_arrival
        start_date = if wrap_time
            minimum(Dates.Date(c.date) for c in commodities)
        else
            minimum(Dates.Date(c.date - c.max_delivery_time) for c in commodities)
        end
    else
        start_date = minimum(Dates.Date(c.date) for c in commodities)
    end

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
    bundles = [Bundle(bundle_dict[key], key[1], key[2]) for key in keys(bundle_dict)]

    # Build mapping from time step index to date
    time_step_to_date = [start_date + (i - 1) * time_step for i in 1:time_horizon_length]

    time_space_graph = TimeSpaceGraph(
        network_graph, time_horizon_length; wrap_time=wrap_time
    )
    travel_time_graph = TravelTimeGraph(network_graph, bundles)
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

Build an `Instance` using the `Arc` interface. This is the recommended constructor.
Automatically converts `Arc` (with time periods) into `NetworkArc` (with time steps) using `collect_arcs`.
"""
function build_instance(
    nodes::Vector{<:NetworkNode},
    raw_arcs::Vector{<:Arc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period,
    arc_cost_types;
    group_by=_default_group_by,
    wrap_time=false,
) where {is_date_arrival,ID,I}
    # If arc_cost_types is a single type, wrap it in a tuple for collect_arcs
    types = arc_cost_types isa Type ? (arc_cost_types,) : arc_cost_types
    arcs = collect_arcs(types, raw_arcs, time_step)
    return build_instance(
        nodes, arcs, commodities, time_step; group_by=group_by, wrap_time=wrap_time
    )
end
