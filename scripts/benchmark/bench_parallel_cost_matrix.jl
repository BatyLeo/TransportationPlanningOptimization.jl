# Microbenchmark for parallel_update_bundle_cost_matrix!
#
# Times N repeated calls on random bundles, reporting wall time, per-call time,
# and allocations. Used to compare the OhMyThreads @tasks chunk-indexed buffer
# pool against the previous @threads :static + threadid() approach, and to check
# thread scaling.
#
# Run with:
#   julia --project=scripts -t <N> scripts/benchmark/bench_parallel_cost_matrix.jl [instance] [n_calls]
# Defaults: small, 2000 calls

using Random
using Printf

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance
using Dates: Week

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")

function load_instance(name::String)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")
    (; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
    return TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

function init_solution(instance)
    filtering_sol = TPO.lower_bound_filtering(instance)
    sub = TPO.extract_filtered_instance(instance, filtering_sol)
    candidates = TPO.mix_greedy_and_lower_bound(sub)
    chosen = TPO.choose_best_feasible(
        [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
    )
    return sub, chosen
end

function run_calls!(sol, instance, buffer_pool, n_calls; rng)
    mode_selector = TPO.CheapestMode()
    n_bundles = length(instance.bundles)
    # gather a fixed sequence of non-empty bundles so old/new see the same work
    idxs = Int[]
    while length(idxs) < n_calls
        b = rand(rng, 1:n_bundles)
        isempty(sol.bundle_paths[b]) || push!(idxs, b)
    end
    # timed loop
    t0 = time_ns()
    allocs = @allocated for b in idxs
        TPO.parallel_update_bundle_cost_matrix!(
            sol, instance, b, mode_selector, buffer_pool; packing=:frozen
        )
    end
    wall = (time_ns() - t0) / 1e9
    return wall, allocs
end

function main()
    name = length(ARGS) >= 1 ? ARGS[1] : "small"
    n_calls = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 2000

    println("nthreads = ", Threads.nthreads())
    println("Loading instance: $name ...")
    instance = load_instance(name)
    sub, sol = init_solution(instance)
    mean_arcs = round(
        Int, sum(length(a) for a in sub.travel_time_graph.bundle_arcs) / length(sub.bundles)
    )
    @printf("  bundles=%d  mean_arcs=%d\n", length(sub.bundles), mean_arcs)

    buffer_pool = TPO.create_buffer_pool()

    # warmup
    run_calls!(sol, sub, buffer_pool, 50; rng=Random.MersenneTwister(1))
    # timed
    wall, allocs = run_calls!(sol, sub, buffer_pool, n_calls; rng=Random.MersenneTwister(42))
    @printf(
        "  %d calls: %.3f s total | %.1f us/call | %.1f calls/s | %.2f MiB (%.2f KiB/call)\n",
        n_calls,
        wall,
        1e6 * wall / n_calls,
        n_calls / wall,
        allocs / 2^20,
        allocs / 1024 / n_calls,
    )
    return nothing
end

main()
