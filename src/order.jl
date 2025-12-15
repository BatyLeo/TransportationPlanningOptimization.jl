struct Order{is_date_arrival,I}
    "list of commodities in the order"
    commodities::Vector{LightCommodity{is_date_arrival,I}}
    "time step corresponding to the delivery arrival/departure date"
    delivery_time_step::Int
    "maximum number of time steps for delivery among all commodities in the order"
    max_delivery_time_step::Int
end

function Order(;
    commodities::Vector{LightCommodity{is_date_arrival,I}},
    delivery_time_step::Int,
    max_delivery_time_step::Int,
) where {is_date_arrival,I}
    return Order{is_date_arrival(commodities[1]),I}(
        commodities, delivery_time_step, max_delivery_time_step
    )
end

function Base.show(io::IO, order::Order)
    return print(
        io,
        "Order(delivery_time_step=$(order.delivery_time_step), num_commodities=$(length(order.commodities)), max_delivery_time_step=$(order.max_delivery_time_step))",
    )
end
