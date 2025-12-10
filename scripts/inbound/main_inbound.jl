using CSV
using Dates
using DataFrames
using NetworkDesignOptimization
includet("Inbound.jl")

instance = "small"
datadir = joinpath(@__DIR__, "..", "..", "data", "inbound2")
nodes_file = joinpath(datadir, "$(instance)_nodes.csv")
legs_file = joinpath(datadir, "$(instance)_legs.csv")
commodities_file = joinpath(datadir, "$(instance)_commodities.csv")

(; nodes, arcs, commodities) = read_inbound_instance(
    nodes_file, legs_file, commodities_file
);

eltype(nodes)
eltype(arcs)
eltype(commodities)

using Graphs, MetaGraphsNext

network_graph = NetworkGraph(nodes, arcs)
