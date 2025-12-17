using NetworkDesignOptimization
includet("Outbound.jl")
using .Outbound

using DataFrames
using CSV
using Dates

# Preprocessing
outbound_data_dir = joinpath(@__DIR__, "..", "..", "data", "outbound")
raw_data_file = joinpath(outbound_data_dir, "raw", "HexData.csv")
data_dir = joinpath(outbound_data_dir, "parsed")
preprocessing_outbound_data(raw_data_file, data_dir; overwrite=false)

node_file = joinpath(data_dir, "parsed_nodes.csv")
leg_file = joinpath(data_dir, "parsed_legs.csv")
commodity_file = joinpath(data_dir, "parsed_volumes.csv")
model_file = joinpath(data_dir, "parsed_models.csv")
load_factor_file = joinpath(data_dir, "load_factor_min_estimated.csv")

(; nodes, arcs, commodities) = read_outbound_instance(
    node_file, leg_file, commodity_file, model_file, load_factor_file
);

instance = build_instance(
    nodes, arcs, commodities, Week(12), (LinearArcCost, BinPackingArcCost)
);
instance

nodes
arcs
commodities

group_cols = [:destinationFinale, :annee, :semaine]
gdf = groupby(df_commodities, group_cols)
