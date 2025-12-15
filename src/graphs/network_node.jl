@kwdef struct NetworkNode{J}
    id::String
    node_type::Symbol = :platform
    cost::Float64 = 0.0
    capacity::Int = typemax(Int)
    info::J = nothing
end
