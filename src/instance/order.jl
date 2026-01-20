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
    time_step::Int
    "maximum number of time steps for delivery among all commodities in the order"
    max_transit_steps::Int

    function Order{is_date_arrival,I}(
        commodities::Vector{LightCommodity{is_date_arrival,I}},
        time_step::Int,
        max_transit_steps::Int,
    ) where {is_date_arrival,I}
        if time_step <= 0
            throw(DomainError(time_step, "Time steps start from 1."))
        end
        if max_transit_steps < 0
            throw(
                DomainError(
                    max_transit_steps, "A number of time steps must be non-negative."
                ),
            )
        end
        return new{is_date_arrival,I}(commodities, time_step, max_transit_steps)
    end
end

function Order(;
    commodities::Vector{LightCommodity{is_date_arrival,I}},
    time_step::Int,
    max_transit_steps::Int,
) where {is_date_arrival,I}
    return Order{is_date_arrival,I}(commodities, time_step, max_transit_steps)
end

function Base.show(io::IO, order::Order)
    return print(
        io,
        "Order(time_step=$(order.time_step), num_commodities=$(length(order.commodities)), max_transit_steps=$(order.max_transit_steps))",
    )
end

"""
$TYPEDSIGNATURES

Compute the total size of all commodities in the order.
"""
function total_size(order::Order)
    return sum(c.size for c in order.commodities; init=0.0)
end
