struct Order{I}
    commodities::Vector{LightCommodity{I}}
    delivery_time_step::Int
    max_delivery_time_step::Int
end
