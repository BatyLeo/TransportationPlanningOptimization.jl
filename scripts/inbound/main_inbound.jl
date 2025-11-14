using CSV
using Dates
using DataFrames
using NetworkDesignOptimization
includet("Inbound.jl")

instance = "world"
datadir = joinpath(@__DIR__, "..", "..", "data", "inbound")
nodes_file = joinpath(datadir, "$(instance)_nodes.csv")
legs_file = joinpath(datadir, "$(instance)_legs.csv")
commodities_file = joinpath(datadir, "$(instance)_commodities.csv")

(; nodes, arcs, commodities) = read_inbound_instance(
    nodes_file, legs_file, commodities_file
);

eltype(nodes)
eltype(arcs)
eltype(commodities)
