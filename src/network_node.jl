@kwdef struct NetworkNode{J}
    id::String
    cost::Float64 = 0.0
    capacity::Int = typemax(Int)
    info::J = nothing
end
