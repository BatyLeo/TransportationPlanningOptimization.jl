struct LightCommodity{is_date_arrival,I}
    origin_id::String
    destination_id::String
    size::Float64
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
