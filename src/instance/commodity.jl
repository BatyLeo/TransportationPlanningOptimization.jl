"""
$TYPEDEF

A `LightCommodity` represents a commodity in the transportation planning problem.
A commodity is defined by its origin and destination nodes, its size, and any additional problem-specific information.
This data structure does include date information, as it is stored in [`Order`](@ref) instead.

# Fields
$TYPEDFIELDS
"""
struct LightCommodity{is_date_arrival,I}
    "id of the origin node"
    origin_id::String
    "id of the destination node"
    destination_id::String
    "size of the commodity, representing the capacity it occupies"
    size::Float64
    "extra information about the commodity, which can be used for problem-specific purposes"
    info::I

    function LightCommodity{is_date_arrival,I}(
        origin_id::String, destination_id::String, size::Float64, info::I
    ) where {is_date_arrival,I}
        if size <= 0.0
            throw(DomainError(size, "LightCommodity size must be positive."))
        end
        return new{is_date_arrival,I}(origin_id, destination_id, size, info)
    end
end

function LightCommodity(;
    origin_id::String,
    destination_id::String,
    size::Float64,
    is_date_arrival::Bool=false,
    info::I=nothing,
) where {I}
    return LightCommodity{is_date_arrival,I}(origin_id, destination_id, size, info)
end

function Base.show(io::IO, commodity::LightCommodity)
    return print(
        io,
        "LightCommodity($(commodity.origin_id) -> $(commodity.destination_id), $(round(commodity.size; digits=2)))",
    )
end
