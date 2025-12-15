using NetworkDesignOptimization
includet("Outbound.jl")
using .Outbound

using Dates

# Preprocessing
raw_data_file = joinpath(@__DIR__, "..", "..", "data", "outbound", "raw", "HexData.csv")
data_dir = joinpath(dirname(raw_data_file), "parsed")
preprocessing_outbound_data(raw_data_file, data_dir; overwrite=false)

##  ---- ###

node_file = joinpath(data_dir, "parsed_nodes.csv")
leg_file = joinpath(data_dir, "parsed_legs.csv")
commodity_file = joinpath(data_dir, "parsed_volumes.csv")

df_nodes, df_legs, df_commodities = read_outbound_instance(
    node_file, leg_file, commodity_file
)

df_commodities = filter(
    row -> !ismissing(row.volumeSemaine) && row.volumeSemaine > 0, df_commodities
)

group_cols = [:destinationFinale, :annee, :semaine]
gdf = groupby(df_commodities, group_cols)

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

commodities = map(eachrow(df_commodities)) do row
    Commodity(;
        origin_id="$(row.usine)",
        destination_id="$(row.destinationFinale)",
        size=Float64(row.volumeSemaine),
        max_delivery_time=Year(1),
        departure_date=DateTime(0),
        info=OutBoundCommodityInfo(row.model, row.typeBT == "BTS"),
    )
end

using Plots
histogram(df_commodities.volumeSemaine[0 .< df_commodities.volumeSemaine .< 100])
extrema(df_commodities.volumeSemaine)

# group by usine, destination, annee, semaine and aggregate

gdf = groupby(df_legs, [:origine, :destination])
gdf[2]

gdf = groupby(
    df_commodities, [:usine, :destinationFinale, :model, :typeBT, :annee, :semaine]
)
