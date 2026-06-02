using TransportationPlanningOptimization
include("Outbound.jl")
using .Outbound

using DataFrames
using CSV
using Dates

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "outbound", "dataMVP")

(; nodes, arcs, commodities) = Outbound.parse_dataMVP_instance(
    DATA_DIR; keep_modes=true, all_linear=true
)
instance = Instance(
    nodes, arcs, commodities, Day(600); wrap_time=false, allow_multimodal=true
)
println(
    "MVP-MULTI Instance: $(length(nodes)) nodes, $(length(arcs)) arcs, $(length(commodities)) commodities",
)

t_greedy = @elapsed sol = greedy_heuristic(instance)
println("MVP-MULTI Greedy: cost=$(cost(sol)) time=$(round(t_greedy; digits=2))s")
