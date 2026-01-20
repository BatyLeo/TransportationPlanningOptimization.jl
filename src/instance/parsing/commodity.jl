"""
$TYPEDEF

User-facing commodity data structure for parsing input data.

This structure is designed to be easy to instantiate from CSV, JSON, or other data sources.
Once all commodities are loaded, they are consolidated into optimized internal structures
(Commodity, Order, Bundle) based on problem-specific consolidation rules.

# Type Parameters
- `is_date_arrival::Bool`: 
    - `true`: `date` represents the **arrival deadline** at the destination.
    - `false`: `date` represents the **earliest departure time** (release) from the origin.
- `ID`: Type for node identifiers (e.g., String, Int).
- `I`: Type for additional problem-specific information.

# Fields
$TYPEDFIELDS

# Examples
```julia
# Inbound logistics (arrival date)
Commodity(
    origin_id = "SUPPLIER_A",
    destination_id = "PLANT_PARIS",
    arrival_date = Date(2025, 11, 20),
    size = 150.0,
    info = (part_id = "ENGINE_V6", priority = :high)
)

# Outbound logistics (departure date)
Commodity(
    origin_id = "PLANT_PARIS",
    destination_id = "DEALER_LYON",
    departure_date = Date(2025, 11, 18),
    size = 1.0,  # 1 vehicle
    info = (model = "Clio", color = "Blue")
)
```
"""
struct Commodity{is_date_arrival,ID,I}
    "origin node identifier"
    origin_id::ID
    "destination node identifier"
    destination_id::ID
    "date information associated with the commodity"
    date::DateTime
    max_delivery_time::Period
    "size of the commodity (we assume 1D approximation)"
    size::Float64
    "quantity of the commodity"
    quantity::Int
    "additional problem-specific information"
    info::I

    function Commodity{is_date_arrival,ID,I}(
        origin_id::ID,
        destination_id::ID,
        date::DateTime,
        max_delivery_time::Period,
        size::Float64,
        quantity::Int,
        info::I,
    ) where {is_date_arrival,ID,I}
        if size <= 0.0
            throw(DomainError(size, "Commodity size must be positive."))
        end
        if quantity <= 0
            throw(DomainError(quantity, "Commodity quantity must be positive."))
        end
        return new{is_date_arrival,ID,I}(
            origin_id, destination_id, date, max_delivery_time, size, quantity, info
        )
    end
end

function Commodity(;
    origin_id::ID,
    destination_id::ID,
    size::Float64,
    quantity::Int=1,
    max_delivery_time::Period,
    arrival_date=nothing,
    departure_date=nothing,
    info::I=nothing,
) where {ID,I}
    # Validate that exactly one of arrival_date or departure_date is provided
    if !isnothing(arrival_date) && !isnothing(departure_date)
        throw(ArgumentError("Cannot specify both arrival_date and departure_date"))
    end

    if isnothing(arrival_date) && isnothing(departure_date)
        throw(ArgumentError("Must specify either arrival_date or departure_date"))
    end

    # Determine which date type and use the provided date
    is_date_arrival = !isnothing(arrival_date)
    actual_date = is_date_arrival ? arrival_date : departure_date

    return Commodity{is_date_arrival,ID,I}(
        origin_id, destination_id, actual_date, max_delivery_time, size, quantity, info
    )
end

function Base.show(
    io::IO, commodity::Commodity{is_date_arrival,ID,I}
) where {is_date_arrival,ID,I}
    date_type = is_date_arrival ? "Arrival Date" : "Departure Date"
    println(io, "Commodity{is_date_arrival=$(is_date_arrival)}:")
    println(io, "  Origin ID: ", commodity.origin_id)
    println(io, "  Destination ID: ", commodity.destination_id)
    println(io, "  $date_type: ", commodity.date)
    println(io, "  Quantity: ", commodity.quantity)
    println(io, "  Size: ", commodity.size)
    println(io, "  Max Delivery Time: ", commodity.max_delivery_time)
    println(io, "  Info: ", commodity.info)
    return nothing
end
