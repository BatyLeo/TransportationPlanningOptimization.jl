# Profile TPO LS with `packing=:frozen` on the large instance. After the
# A/B test showed :frozen only gives 1.1-1.9x iter/s gain at the LS level
# (vs 10.7x predicted by the single-call microbench), we need to see what's
# now dominating the LS time once the :ffd_union overhead is gone.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Profile
using Printf

const PROFILE_INSTANCE = get(ENV, "PROFILE_INSTANCE", "large")
const PROFILE_BUDGET = parse(Float64, get(ENV, "PROFILE_BUDGET", "30"))
const PACKING = Symbol(get(ENV, "PACKING", "frozen"))

println("=== Setting up TPO instance: $PROFILE_INSTANCE (packing=$PACKING) ===")
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

println("=== JIT warmup LS (1s, packing=$PACKING) ===")
TPO.local_search!(deepcopy(chosen), sub; time_limit=1.0, packing=PACKING)
GC.gc()

println(
    "=== Profile LS ($(PROFILE_BUDGET)s budget) on $PROFILE_INSTANCE, packing=$PACKING ==="
)
Profile.clear()
Profile.init(; n=10_000_000, delay=0.001)
chosen_profile = deepcopy(chosen)
result = @profile TPO.local_search!(
    chosen_profile, sub; time_limit=PROFILE_BUDGET, packing=PACKING
)
println("LS done: $(result.n_iter) iters, saved $(round(result.saved; digits=1))")
println("iter/s: $(round(result.n_iter / PROFILE_BUDGET; digits=1))")

println("\n=== Flat profile, sorted by self time (top 30) ===")
Profile.print(; format=:flat, mincount=100, sortedby=:count, noisefloor=2.0)

println("\n=== Tree profile (mincount=300) ===")
Profile.print(; format=:tree, mincount=300, sortedby=:count, noisefloor=2.0)

println("\n=== Function-sample counts (frame matches, can overcount) ===")
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

total = count(!=(0), data)
for needle in (
    "update_bundle_cost_matrix",
    "compute_ttg_edge_incremental_cost",
    "_edge_incremental_cost",
    "frozen_incremental_cost",
    "incremental_cost",
    "add_bundle_path",
    "remove_bundle_path",
    "_try_reinsert_bundle",
    "two_node_common_incremental",
    "dijkstra_shortest_paths",
    "bundle_estimated_removal_cost",
    "ffd_count",
    "frozen_incremental_count",
    "_remove_commodities",
    "_drain_first_n",
    "_add_order_to_assignment",
    "merge_bundles",
    "splice_path",
    "cost",
)
    n = count_function(needle, data, lidict)
    pct = round(100 * n / max(total, 1); digits=1)
    @printf("%-50s %8d frames (%5.1f%%)\n", needle, n, pct)
end
