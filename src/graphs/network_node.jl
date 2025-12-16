@kwdef struct NetworkNode{J}
    id::String
    node_type::Symbol = :platform
    cost::Float64 = 0.0
    capacity::Int = typemax(Int)
    info::J = nothing
end

function Base.show(io::IO, node::NetworkNode)
    return print(
        io,
        "NetworkNode(",
        "id=$(node.id), ",
        "node_type=$(node.node_type), ",
        "cost=$(node.cost), ",
        "capacity=$(node.capacity == typemax(Int) ? "∞" : string(node.capacity)), ",
        "info=$(node.info)",
        ")",
    )
end
