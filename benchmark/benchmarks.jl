using BenchmarkTools
using Dates
using TransportationPlanningOptimization

include(joinpath(@__DIR__, "..", "test", "Inbound.jl"))
using .Inbound

const SUITE = BenchmarkGroup()
SUITE["greedy"] = BenchmarkGroup()

const REPO_ROOT = joinpath(@__DIR__, "..")

function load_instance(datadir::String, name::String)
    nodes_file = joinpath(REPO_ROOT, datadir, "$(name)_nodes.csv")
    legs_file = joinpath(REPO_ROOT, datadir, "$(name)_legs.csv")
    commodities_file = joinpath(REPO_ROOT, datadir, "$(name)_commodities.csv")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        nodes_file, legs_file, commodities_file
    )
    return Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

for (label, datadir, name) in [
    ("tiny", "data/inbound2", "tiny"),
    ("small", "data/inbound", "small"),
    ("medium", "data/inbound", "medium"),
]
    instance = load_instance(datadir, name)
    SUITE["greedy"][label] = if label == "tiny"
        @benchmarkable greedy_heuristic($instance)
    else
        @benchmarkable greedy_heuristic($instance) evals = 1 samples = 1
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    result = BenchmarkTools.run(SUITE; verbose=true)
    println()
    show(result)
    println()
end
