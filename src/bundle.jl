struct Bundle{O<:Order}
    orders::Vector{O}
    origin_id::String
    destination_id::String
end
