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
    "time expanded graph (for order paths)"
    time_space_graph::TSG
    "travel time graph (for bundle paths)"
    travel_time_graph::TTG
end

function Base.show(io::IO, instance::Instance)
    nb_orders = sum(length(bundle.orders) for bundle in instance.bundles)
    nb_commodities = sum(
        length(order.commodities) for bundle in instance.bundles for order in bundle.orders
    )
    padding = length(string(nb_commodities))
    println(io, "Instance Summary:")
    println(
        io,
        "  • Horizon: $(lpad(string(instance.time_horizon_length) * " time steps", 0)) ($(instance.time_step) per step)",
    )
    println(io, "  • Commodities: $(lpad(nb_commodities, padding))")
    println(io, "  • Orders:      $(lpad(nb_orders, padding))")
    println(io, "  • Bundles:     $(lpad(length(instance.bundles), padding))")
    print(io, "  • ", instance.network_graph)
    print(io, "  • ", instance.time_space_graph)
    print(io, "  • ", instance.travel_time_graph)
    return nothing
end

function time_horizon(instance::Instance)
    return 1:(instance.time_horizon_length)
end

function build_instance(
    nodes::Vector{<:NetworkNode},
    arcs::Vector{<:Tuple{String,String,<:NetworkArc}},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period,
) where {is_date_arrival,ID,I}
    # Building the network graph (arcs are provided as (origin_id,destination_id,NetworkArc))
    network_graph = NetworkGraph(nodes, arcs)

    # Wrapping commodities into light commodities
    full_commodities = LightCommodity{is_date_arrival,I}[]
    # Key is (time_step_idx, origin_id, destination_id), value is (vector of LightCommodity, min_delivery_time_steps)
    order_dict = Dict{
        Tuple{Int,String,String},Tuple{Vector{LightCommodity{is_date_arrival,I}},Int}
    }()

    # normalize all dates to Date so DateTime operands are handled consistently
    start_date = minimum(Dates.Date.([c.date for c in commodities]))
    for comm in commodities
        to_append = [
            LightCommodity(;
                origin_id=comm.origin_id,
                destination_id=comm.destination_id,
                size=comm.size,
                info=comm.info,
                is_date_arrival=is_date_arrival,
            ) for _ in 1:(comm.quantity)
        ]
        max_delivery_time_steps = period_steps(
            comm.max_delivery_time, time_step; roundup=floor
        )
        append!(full_commodities, to_append)
        # time_step_idx relative to the earliest arrival_date (discretized by time_step)
        time_step_idx =
            period_steps(Dates.Date(comm.date) - start_date, time_step; roundup=floor) + 1
        key = (time_step_idx, comm.origin_id, comm.destination_id)

        if haskey(order_dict, key)
            commodities_list, min_steps = order_dict[key]
            append!(commodities_list, to_append)
            order_dict[key] = (commodities_list, min(min_steps, max_delivery_time_steps))
        else
            order_dict[key] = (to_append, max_delivery_time_steps)
        end
    end
    time_horizon_length = maximum(key[1] for key in keys(order_dict))

    # Build orders and bundles simultaneously in one pass
    bundle_dict = Dict{Tuple{String,String},Vector{Order{is_date_arrival,I}}}()
    orders = Order{is_date_arrival,I}[]

    for key in keys(order_dict)
        time_step_idx, origin_id, dest_id = key
        commodities_list, min_steps = order_dict[key]
        min_steps = min(time_horizon_length, min_steps)
        order = Order{is_date_arrival,I}(commodities_list, time_step_idx, min_steps)
        push!(orders, order)

        bundle_key = (origin_id, dest_id)
        if haskey(bundle_dict, bundle_key)
            push!(bundle_dict[bundle_key], order)
        else
            bundle_dict[bundle_key] = [order]
        end
    end
    bundles = [Bundle(bundle_dict[key], key[1], key[2]) for key in keys(bundle_dict)]

    time_space_graph = TimeSpaceGraph(network_graph, time_horizon_length)
    travel_time_graph = TravelTimeGraph(network_graph, bundles)
    return Instance(;
        time_horizon_length,
        time_step,
        bundles,
        network_graph,
        time_space_graph,
        travel_time_graph,
    )
end

function build_instance(
    nodes::Vector{<:NetworkNode},
    raw_arcs::Vector{<:Arc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period,
    arc_cost_types, # TODO: have two methods, one with tuple of types, and a shorcut with only a single type
) where {is_date_arrival,ID,I}
    arcs = collect_arcs(arc_cost_types, raw_arcs, time_step)
    return build_instance(nodes, arcs, commodities, time_step)
end
