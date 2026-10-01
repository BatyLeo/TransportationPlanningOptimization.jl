"""
$TYPEDSIGNATURES

Order-level summary of `commodities`, stored in `Order.aggregate`.
Returns any value summarizing the commodities of one order.
Called once at construction, on the commodities sorted by decreasing size.
Must return the same type for every order of a problem, so that order containers stay concretely typed.
Returns `nothing` by default, problems can overload it for their own commodity info type.
"""
order_aggregate(::Vector{<:LightCommodity}) = nothing

# Private token: only the validating constructor may call the raw field constructor.
struct _CheckedOrder end

"""
$TYPEDEF

An internal structure representing a group of commodities to be delivered together.
The commodities are sorted in descending order of size to facilitate packing
heuristics.
Commodities in an `Order` share the same:
- Origin node
- Destination node
- Delivery date (interpreted as a deadline or release depending on `is_date_arrival` value)

The only public way to build an `Order` is `Order{is_date_arrival,I}(commodities, time_step, max_transit_steps)`
(or the keyword constructor), which validates the inputs, sorts the commodities
and infers the aggregate type `A` from [`order_aggregate`](@ref).

# Type Parameters
- `is_date_arrival::Bool`: `true` for deadline-driven, `false` for release-driven orders.
- `I`: Additional problem-specific information type.
- `A`: Type of the order-level aggregate returned by [`order_aggregate`](@ref).

# Fields
$TYPEDFIELDS
"""
struct Order{is_date_arrival,I,A}
    "list of commodities in the order, **kept sorted by descending size**"
    commodities::Vector{LightCommodity{I}}
    "time step corresponding to the delivery arrival or departure date"
    time_step::Int
    "maximum number of time steps for delivery (among all commodities in the order)"
    max_transit_steps::Int
    "precomputed sum of all commodity sizes"
    total_size::Float64
    "order-level summary of the commodities (see [`order_aggregate`](@ref)), `nothing` by default"
    aggregate::A

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
        sort!(commodities; by=c -> c.size, rev=true)
        ts = sum(c.size for c in commodities; init=0.0)
        return Order{is_date_arrival,I}(
            _CheckedOrder(),
            commodities,
            time_step,
            max_transit_steps,
            ts,
            order_aggregate(commodities),
        )
    end

    function Order{is_date_arrival,I}(
        ::_CheckedOrder,
        commodities::Vector{LightCommodity{I}},
        time_step::Int,
        max_transit_steps::Int,
        ts::Float64,
        agg::A,
    ) where {is_date_arrival,I,A}
        return new{is_date_arrival,I,A}(commodities, time_step, max_transit_steps, ts, agg)
    end
end

"""
$TYPEDSIGNATURES

Construct an [`Order`](@ref) from a list of [`LightCommodity`](@ref).
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
