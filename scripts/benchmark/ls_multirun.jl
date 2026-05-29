# Stable LS comparison: run TPO LS N times each setting, report median iter/s.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Printf, Statistics, Random

const INSTANCE = get(ENV, "INSTANCE", "medium")
const LS_BUDGET = parse(Float64, get(ENV, "LS_BUDGET", "15"))
const N_RUNS = parse(Int, get(ENV, "N_RUNS", "5"))

println("=== Setup TPO instance: $INSTANCE ===")
nodes_file = joinpath(DATA_DIR, "$(INSTANCE)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(INSTANCE)_legs.csv")
com_file = joinpath(DATA_DIR, "$(INSTANCE)_commodities.csv")
(; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

println("=== Filter + init ===")
filtering_sol = TPO.lower_bound_filtering(instance)
sub = TPO.extract_filtered_instance(instance, filtering_sol)
candidates = TPO.mix_greedy_and_lower_bound(sub)
chosen = TPO.choose_best_feasible(
    [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
)

println("=== Warmup ===")
TPO.local_search!(deepcopy(chosen), sub; time_limit=1.0, packing=:frozen)
GC.gc()

function run_n(label, packing, n_runs, seed_base)
    iters = Float64[]
    times = Float64[]
    println("\n--- $label ($n_runs runs, $(LS_BUDGET)s each, seed_base=$seed_base) ---")
    for i in 1:n_runs
        sol = deepcopy(chosen)
        Random.seed!(seed_base + i)
        t = @elapsed result = TPO.local_search!(
            sol, sub; time_limit=LS_BUDGET, packing=packing,
        )
        ips = result.n_iter / t
        push!(iters, result.n_iter)
        push!(times, t)
        @printf("  run %d: %d iters in %.2fs → %.1f iter/s\n", i, result.n_iter, t, ips)
        GC.gc()
    end
    ips = iters ./ times
    @printf("  → median %.1f iter/s, min %.1f, max %.1f, mean %.1f, stddev %.1f\n",
        median(ips), minimum(ips), maximum(ips), mean(ips), std(ips))
    return median(ips)
end

# With the merge-on-add change applied, this is now just a straight median run.
println("\n" * "="^60)
println("Current TPO (drain adaptive + merge-on-add) — $N_RUNS runs each")
println("="^60)
m_frozen = run_n("packing=:frozen", :frozen, N_RUNS, 1000)
m_union = run_n("packing=:ffd_union", :ffd_union, N_RUNS, 2000)

@printf("\n=== Median iter/s across %d runs ===\n", N_RUNS)
@printf("  :frozen     %.1f iter/s\n", m_frozen)
@printf("  :ffd_union  %.1f iter/s\n", m_union)
