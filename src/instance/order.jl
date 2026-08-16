"""
$TYPEDEF

An internal structure representing a group of commodities to be delivered together.
Commodities in an `Order` share the same:
- Origin node
- Destination node
- Delivery date (interpreted as a deadline or release depending on `is_date_arrival` value)

# Type Parameters
- `is_date_arrival::Bool`: `true` for deadline-driven, `false` for release-driven orders.
- `I`: Additional problem-specific information.

# Fields
$TYPEDFIELDS
"""
struct Order{is_date_arrival,I}
    "list of commodities in the order, **kept sorted by descending size**"
    commodities::Vector{LightCommodity{I}}
    "time step corresponding to the delivery arrival or departure date"
    time_step::Int
    "maximum number of time steps for delivery (among all commodities in the order)"
    max_transit_steps::Int
    "precomputed sum of all commodity sizes"
    total_size::Float64

    function Order{is_date_arrival,I}(
        commodities::Vector{LightCommodity{I}}, time_step::Int, max_transit_steps::Int
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
        # Sort commodities by size descending to facilitate packing heuristics.
        sort!(commodities; by=c -> c.size, rev=true)
        ts = sum(c.size for c in commodities; init=0.0)
        return new{is_date_arrival,I}(commodities, time_step, max_transit_steps, ts)
    end
end

"""
$TYPEDSIGNATURES

Construct an `Order` from a list of `LightCommodity`.
The commodities are sorted (inline) in descending order of size to facilitate packing
heuristics.
"""
function Order(;
    commodities::Vector{LightCommodity{I}},
    time_step::Int,
    max_transit_steps::Int,
    is_date_arrival::Bool=false,
) where {I}
    return Order{is_date_arrival,I}(commodities, time_step, max_transit_steps)
end

function Base.show(io::IO, order::Order{is_date_arrival,I}) where {is_date_arrival,I}
    date_kind = is_date_arrival ? "arrival_date" : "departure_date"
    return print(
        io,
        "Order($date_kind=$(order.time_step), " *
        "num_commodities=$(length(order.commodities)), " *
        "max_transit_steps=$(order.max_transit_steps))",
    )
end

"""
$TYPEDSIGNATURES

Total size of all commodities in the order (precomputed at construction).
"""
total_size(order::Order) = order.total_size
