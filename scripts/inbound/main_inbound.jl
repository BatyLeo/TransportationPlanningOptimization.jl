using CSV
using DataFrames
using NetworkDesignOptimization
includet("Inbound.jl")

instance = "small"
datadir = joinpath(@__DIR__, "..", "..", "data", "inbound", "data")
nodes_file = joinpath(datadir, "$(instance)_nodes.csv")
legs_file = joinpath(datadir, "$(instance)_legs.csv")
commodities_file = joinpath(datadir, "$(instance)_commodities.csv")

df_nodes, df_legs, df_commodities = read_inbound_instance(
    nodes_file, legs_file, commodities_file
)

nodes = map(eachrow(df_nodes)) do row
    NetworkNode(;
        id="$(row[NODE_ID])",
        cost=row[NODE_COST],
        capacity=Int(row[NODE_CAPACITY]),
        info=InboundNodeInfo(Symbol(row[NODE_TYPE])),
    )
end;
typeof(nodes)

# Create arcs naturally without worrying about types
raw_arcs = map(eachrow(df_legs)) do row
    cost = if row.is_linear
        LinearArcCost(row.shipment_cost)
    else
        BinPackingArcCost(row.shipment_cost, row.capacity)
    end
    return NetworkArc(;
        origin_id="$(row.src_account)", destination_id="$(row.dst_account)", cost=cost
    )
end
typeof(raw_arcs)

# Automatically convert to type-stable union
arcs = collect_arcs((LinearArcCost, BinPackingArcCost), raw_arcs)
typeof(arcs)

function f(arcs::Vector{<:NetworkArc})
    total = 0.0
    for arc in arcs
        total += evaluate(arc.cost)
    end
    return total
end

@code_warntype f(arcs)
@code_warntype f(raw_arcs)
