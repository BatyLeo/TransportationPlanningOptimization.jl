# Focused hot-path microbenchmark for add_bundle_path! / remove_bundle_path!.
# Used to check that the _foreach_path_edge refactor is allocation- and
# time-neutral (a refactor regression shows up as extra allocations).
#
# Run: julia --project=test scripts/benchmark/bench_path_ops.jl [medium]

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using Dates, Printf, Statistics
using BenchmarkTools

isdefined(Main, :Inbound) || include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound

const DATA = joinpath(@__DIR__, "..", "..", "data", "inbound")
name = length(ARGS) >= 1 ? ARGS[1] : "medium"

(; nodes, arcs, commodities) = Inbound.parse_inbound_instance(
    joinpath(DATA, "$(name)_nodes.csv"),
    joinpath(DATA, "$(name)_legs.csv"),
    joinpath(DATA, "$(name)_commodities.csv"),
)
instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
sol = TPO.greedy_heuristic(instance)

# Pick a handful of non-trivial bundle paths to cycle through.
idxs = [i for i in 1:length(sol.bundle_paths) if length(sol.bundle_paths[i]) >= 3]
sample = idxs[1:min(50, length(idxs))]
paths = Dict(i => copy(sol.bundle_paths[i]) for i in sample)

# One LS-style move: remove a bundle's path then re-add it on the same path.
function cycle!(sol, instance, sample, paths)
    s = 0.0
    for i in sample
        s += TPO.remove_bundle_path!(sol, instance, i)
        s += TPO.add_bundle_path!(sol, instance, i, copy(paths[i]))
    end
    return s
end

# warmup + correctness: a remove+add cycle keeps the solution feasible (cost may
# drift slightly because frozen-bin packing is insertion-order dependent).
cycle!(sol, instance, sample, paths)
@assert TPO.is_feasible(sol, instance) "cycle produced an infeasible solution"

t = @belapsed cycle!($sol, $instance, $sample, $paths)
allocs = @allocated cycle!(sol, instance, sample, paths)
@printf(
    "[%s] %d moves/cycle | %.1f µs/cycle | %.2f µs/move | %d bytes/cycle\n",
    name,
    length(sample),
    t * 1e6,
    t * 1e6 / length(sample),
    allocs
)
