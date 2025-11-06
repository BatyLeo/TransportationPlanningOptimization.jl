using CSV
using DataFrames
using NetworkDesignOptimization
includet(joinpath(@__DIR__, "application_specific", "Inbound.jl"))

instance = "small"
datadir = joinpath(@__DIR__, "..", "data", "inbound", "data")
nodes_file = joinpath(datadir, "$(instance)_nodes.csv")
legs_file = joinpath(datadir, "$(instance)_legs.csv")
commodities_file = joinpath(datadir, "$(instance)_commodities.csv")

df_nodes, df_legs, df_commodities = read_inbound_instance(
    nodes_file, legs_file, commodities_file
)

nodes = map(eachrow(df_nodes)) do row
    NetworkNode(;
        id="$(row.point_account)",
        cost=row.point_m3_cost,
        capacity=Int(row.point_m3_capacity),
        info=InboundNodeInfo(Symbol(row.point_type)),
    )
end

df_legs
arcs = map(eachrow(df_legs)) do row
    cost = if row.is_linear
        LinearArcCost(row.shipment_cost)
    else
        BinPackingArcCost(row.shipment_cost, row.capacity)
    end
    NetworkArc(; origin_id="$(row.src_account)", destination_id="$(row.dst_account)", cost)
end
@code_warntype arcs == nothing
