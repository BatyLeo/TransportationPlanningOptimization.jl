@kwdef struct Instance{B<:Bundle,G<:NetworkGraph}
    bundles::Vector{B}
    network_graph::G
    time_space_graph::Nothing = nothing    # Placeholder for future use
    travel_time_graph::Nothing = nothing   # Placeholder for future use
end

function Base.show(io::IO, instance::Instance)
    nb_orders = sum(length(bundle.orders) for bundle in instance.bundles)
    nb_commodities = sum(
        length(order.commodities) for bundle in instance.bundles for order in bundle.orders
    )
    println(
        io,
        "Instance with $(length(instance.bundles)) bundles, $nb_orders orders, and $nb_commodities commodities.",
    )
    return println(io, instance.network_graph)
end

function build_instance(
    nodes::Vector{<:NetworkNode},
    arcs::Vector{<:NetworkArc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step,
) where {is_date_arrival,ID,I}
    # building the network graph
    network_graph = NetworkGraph(nodes, arcs)
    # wrapping commodities into light commodities
    full_commodities = LightCommodity{is_date_arrival,I}[]
    # Key is (time_step_idx, origin_id, destination_id), value is (vector of LightCommodity, min_delivery_time_steps)
    order_dict = Dict{
        Tuple{Int,String,String},Tuple{Vector{LightCommodity{is_date_arrival,I}},Int}
    }()

    # normalize all dates to Date so DateTime operands are handled consistently
    start_date = minimum(Dates.Date.([c.date for c in commodities]))
    for comm in commodities
        to_append = [
            LightCommodity{is_date_arrival,I}(
                comm.origin_id, comm.destination_id, comm.size, comm.info
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

    # Build orders and bundles simultaneously in one pass
    bundle_dict = Dict{Tuple{String,String},Vector{Order{is_date_arrival,I}}}()
    orders = Order{is_date_arrival,I}[]

    for key in keys(order_dict)
        time_step_idx, origin_id, dest_id = key
        commodities_list, min_steps = order_dict[key]
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
    return Instance(; bundles, network_graph)
end
