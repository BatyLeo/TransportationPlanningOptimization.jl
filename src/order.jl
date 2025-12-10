struct Order{is_date_arrival,I}
    commodities::Vector{LightCommodity{is_date_arrival,I}}
    delivery_time_step::Int
    max_delivery_time::DateTime
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
        "Order(delivery_time_step=$(order.delivery_time_step), num_commodities=$(length(order.commodities)), max_delivery_time=$(order.max_delivery_time))",
    )
end
