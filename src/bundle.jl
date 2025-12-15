struct Bundle{O<:Order}
    orders::Vector{O}
    origin_id::String
    destination_id::String
end

function Bundle(; orders::Vector{O}, origin_id::String, destination_id::String) where {O<:Order}
    return Bundle{O}(orders, origin_id, destination_id)
end
