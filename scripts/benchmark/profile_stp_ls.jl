# Profile STP's `local_search!` single-threaded on the medium instance, to
# compare per-iteration cost breakdown against TPO's profile (in profile_ls.jl).
include(joinpath(@__DIR__, "compare_packages.jl"))

using Profile
using Printf

const PROFILE_INSTANCE = get(ENV, "PROFILE_INSTANCE", "medium")
const PROFILE_BUDGET = parse(Float64, get(ENV, "PROFILE_BUDGET", "30"))

println("=== nthreads = $(Threads.nthreads()) ===")
println("=== Setting up STP instance: $PROFILE_INSTANCE ===")
nodes_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_legs.csv")
com_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_commodities.csv")

instance = STP.read_instance(nodes_file, legs_file, com_file)
instance = STP.add_properties(instance, STP.tentative_first_fit, Int[])

println("=== Filter + init solution ===")
filtering_sol = STP.Solution(instance)
STP.lower_bound_filtering!(filtering_sol, instance)
sub = STP.extract_filtered_instance(instance, filtering_sol)
sub = STP.add_properties(sub, STP.tentative_first_fit, Int[])
mix_sol = STP.Solution(sub)
greedy_sol, lb_sol = STP.mix_greedy_and_lower_bound!(mix_sol, sub)

# Pick best feasible (same logic as run_stp)
candidates = [mix_sol, greedy_sol, lb_sol]
feasible = filter(s -> STP.is_feasible(sub, s), candidates)
pool = isempty(feasible) ? candidates : feasible
costs = [STP.compute_cost(sub, s) for s in pool]
chosen = STP.solution_deepcopy(pool[argmin(costs)], sub)

println("=== JIT warmup LS (1s) ===")
let warm = STP.solution_deepcopy(chosen, sub)
    STP.local_search!(warm, sub; timeLimit=Int(1), verbose=false)
end
GC.gc()

println("=== Profile STP LS ($(PROFILE_BUDGET)s budget) on $PROFILE_INSTANCE ===")
Profile.clear()
Profile.init(; n=10_000_000, delay=0.001)
profile_sol = STP.solution_deepcopy(chosen, sub)
pre_cost = STP.compute_cost(sub, profile_sol)
t = @elapsed @profile STP.local_search!(
    profile_sol, sub; timeLimit=Int(PROFILE_BUDGET), verbose=false
)
post_cost = STP.compute_cost(sub, profile_sol)
println("LS wall time: $(round(t; digits=2))s, saved $(round(pre_cost - post_cost; digits=1))")

println("\n=== Flat profile, top consumers ===")
Profile.print(; format=:flat, mincount=50, sortedby=:count, noisefloor=2.0)

println("\n=== Counting hot function calls ===")
data, lidict = Profile.retrieve()

function count_function(needle::String, data, lidict)
    n = 0
    for ip in data
        ip == 0 && continue
        sf_list = get(lidict, ip, nothing)
        sf_list === nothing && continue
        for sf in sf_list
            if occursin(needle, string(sf.func))
                n += 1
                break
            end
        end
    end
    return n
end

total_samples = count(!=(0), data)
for needle in (
    "parallel_update_cost_matrix", "arc_update_cost",
    "parallel_greedy_insertion", "parallel_greedy_path",
    "dijkstra_shortest_paths",
    "parallel_bundle_reintroduction", "bundle_reintroduction",
    "parallel_two_node_common", "two_node_common",
    "update_solution", "tentative",
    "first_fit", "best_fit",
    "compute_cost", "is_feasible",
    "SparseArrays", "getindex", "setindex",
)
    n = count_function(needle, data, lidict)
    pct = round(100 * n / max(total_samples, 1); digits=1)
    @printf("%-50s %8d samples (%5.1f%%)\n", needle, n, pct)
end
