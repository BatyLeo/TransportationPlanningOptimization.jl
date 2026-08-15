# Profile TPO's `local_search!` to verify which operations dominate the LS loop.
# Hypothesis: `cost(sol)` called twice per two-node iteration is the bottleneck.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Profile
using Dates

const PROFILE_INSTANCE = get(ENV, "PROFILE_INSTANCE", "medium")
const PROFILE_BUDGET = parse(Float64, get(ENV, "PROFILE_BUDGET", "30"))

println("=== Setting up TPO instance: $PROFILE_INSTANCE ===")
nodes_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_legs.csv")
com_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_commodities.csv")

(; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

println("=== Filter + init solution ===")
filtering_sol = TPO.lower_bound_filtering(instance)
sub = TPO.extract_filtered_instance(instance, filtering_sol)
candidates = TPO.mix_greedy_and_lower_bound(sub)
chosen = TPO.choose_best_feasible(
    [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
)

println("=== JIT warmup LS (1s) ===")
TPO.local_search!(deepcopy(chosen), sub; time_limit=1.0)
GC.gc()

println("=== Profile LS ($(PROFILE_BUDGET)s budget) on $PROFILE_INSTANCE ===")
Profile.clear()
Profile.init(; n=10_000_000, delay=0.001)
chosen_profile = deepcopy(chosen)
result = @profile TPO.local_search!(chosen_profile, sub; time_limit=PROFILE_BUDGET)
println("LS done: $(result.n_iter) iters, saved $(round(result.saved; digits=1))")

println("\n=== Flat profile, sorted by self time (top consumers) ===")
Profile.print(; format=:flat, mincount=50, sortedby=:count, noisefloor=2.0)

println("\n=== Tree profile (mincount=200) ===")
Profile.print(; format=:tree, mincount=200, sortedby=:count, noisefloor=2.0)

println("\n=== Counting cost(sol) and update_bundle_cost_matrix! calls in profile ===")
data, lidict = Profile.retrieve()

function count_function(needle::String, data, lidict)
    n = 0
    for ip in data
        ip == 0 && continue
        sf_list = get(lidict, ip, nothing)
        sf_list === nothing && continue
        for sf in sf_list
            funcname = string(sf.func)
            if occursin(needle, funcname)
                n += 1
                break
            end
        end
    end
    return n
end

total_samples = count(!=(0), data)
for needle in (
    "cost",
    "update_bundle_cost_matrix",
    "dijkstra_shortest_paths",
    "add_bundle_path",
    "remove_bundle_path",
    "splice_path",
    "compute_ttg_edge_incremental_cost",
    "tentative_bin_count",
    "_try_reinsert_bundle",
    "two_node_common_incremental",
)
    n = count_function(needle, data, lidict)
    pct = round(100 * n / max(total_samples, 1); digits=1)
    @printf("%-50s %8d samples (%5.1f%%)\n", needle, n, pct)
end
