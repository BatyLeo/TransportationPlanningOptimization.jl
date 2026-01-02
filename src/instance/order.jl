"""
$TYPEDEF

An internal structure representing a group of commodities to be delivered together.
Commodities in an `Order` share the same:
- Origin node
- Destination node
- Delivery date (interpreted as a deadline or release depending on `is_date_arrival`)

# Type Parameters
- `is_date_arrival::Bool`: Inherited from the commodities. `true` for deadline-driven, `false` for release-driven.
- `I`: Additional problem-specific information.

# Fields
$TYPEDFIELDS
"""
struct Order{is_date_arrival,I}
    "list of commodities in the order"
    commodities::Vector{LightCommodity{is_date_arrival,I}}
    "time step corresponding to the delivery arrival/departure date"
    delivery_time_step::Int
    "maximum number of time steps for delivery among all commodities in the order"
    max_delivery_time_step::Int

    function Order{is_date_arrival,I}(
        commodities::Vector{LightCommodity{is_date_arrival,I}},
        delivery_time_step::Int,
        max_delivery_time_step::Int,
    ) where {is_date_arrival,I}
        if delivery_time_step <= 0
            throw(DomainError(delivery_time_step, "Time steps start from 1."))
        end
        if max_delivery_time_step < 0
            throw(
                DomainError(
                    max_delivery_time_step, "A number of time steps must be non-negative."
                ),
            )
        end
        return new{is_date_arrival,I}(
            commodities, delivery_time_step, max_delivery_time_step
        )
    end
end

function Order(;
    commodities::Vector{LightCommodity{is_date_arrival,I}},
    delivery_time_step::Int,
    max_delivery_time_step::Int,
) where {is_date_arrival,I}
    return Order{is_date_arrival,I}(commodities, delivery_time_step, max_delivery_time_step)
end

function Base.show(io::IO, order::Order)
    return print(
        io,
        "Order(delivery_time_step=$(order.delivery_time_step), num_commodities=$(length(order.commodities)), max_delivery_time_step=$(order.max_delivery_time_step))",
    )
end
