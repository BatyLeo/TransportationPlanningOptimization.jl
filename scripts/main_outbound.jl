using NetworkDesignOptimization
includet(joinpath(@__DIR__, "application_specific", "Outbound.jl"))

data_dir = joinpath(@__DIR__, "..", "data", "outbound", "parsed")
node_file = joinpath(data_dir, "parsed_nodes.csv")
leg_file = joinpath(data_dir, "parsed_legs.csv")
commodity_file = joinpath(data_dir, "parsed_volumes.csv")

df_nodes, df_legs, df_commodities = read_outbound_instance(
    node_file, leg_file, commodity_file
)

nodes = map(eachrow(df_nodes)) do row
    list = if ismissing(row.ListeCandidatStockBTS)
        Int[]
    else
        parse.(Int, split(row.ListeCandidatStockBTS, ";")[1:(end - 1)])
    end
    NetworkNode(; id="$(row.indice)", info=OutboundNodeInfo(Symbol(row.TypeNode), list))
end

arcs = map(eachrow(df_legs)) do row
    NetworkArc(;
        origin_id="$(row.origine)",
        destination_id="$(row.destination)",
        capacity=row.VolMax,
        cost=LinearArcCost(row.Cost),
    )
end

df_commodities = filter(
    row -> !ismissing(row.volumeSemaine) && row.volumeSemaine > 0, df_commodities
)

commodities = map(eachrow(df_commodities)) do row
    Commodity(;
        origin_id="$(row.usine)",
        destination_id="$(row.destinationFinale)",
        size=row.volumeSemaine,
        info=OutBoundCommodityInfo(row.model, row.typeBT == "BTS"),
    )
end

using Plots
histogram(df_commodities.volumeSemaine[df_commodities.volumeSemaine .< 100])
minimum(df_commodities.volumeSemaine)
