struct Order{I}
    commodities::Vector{Commodity{I}}
    delivery_time_step::Int
    max_delivery_time_step::Int
end
