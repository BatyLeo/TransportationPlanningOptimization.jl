using CSV
using DataFrames
using Graphs, MetaGraphsNext
using NetworkDesignOptimization
includet("Inbound.jl")

instance_name = "small"
datadir = joinpath(@__DIR__, "..", "..", "data", "inbound2")
nodes_file = joinpath(datadir, "$(instance_name)_nodes.csv")
legs_file = joinpath(datadir, "$(instance_name)_legs.csv")
commodities_file = joinpath(datadir, "$(instance_name)_commodities.csv")

(; nodes, arcs, commodities) = read_inbound_instance(
    nodes_file, legs_file, commodities_file
);

eltype(nodes)
eltype(arcs)
eltype(commodities)

instance = build_instance(nodes, arcs, commodities, Week(1));
instance
