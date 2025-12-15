struct LightCommodity{is_date_arrival,I}
    origin_id::String
    destination_id::String
    # date::DateTime
    size::Float64
    info::I
end

function LightCommodity(;
    origin_id::String,
    destination_id::String,
    size::Float64,
    info::I,
    is_date_arrival::Bool=false,
) where {I}
    return LightCommodity{is_date_arrival,I}(origin_id, destination_id, size, info)
end

function Base.show(io::IO, commodity::LightCommodity)
    return print(
        io,
        "LightCommodity($(commodity.origin_id) -> $(commodity.destination_id), $(round(commodity.size; digits=2)))",
    )
end
