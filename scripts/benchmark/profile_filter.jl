# Profile TPO's `lower_bound_filtering` to find what makes it 2.28x slower
# than STP's on extra_large.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Profile
using Printf

const PROFILE_INSTANCE = get(ENV, "PROFILE_INSTANCE", "medium")

println("=== Setting up TPO instance: $PROFILE_INSTANCE ===")
nodes_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_legs.csv")
com_file = joinpath(DATA_DIR, "$(PROFILE_INSTANCE)_commodities.csv")

(; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

println("=== JIT warmup ===")
TPO.lower_bound_filtering(instance)
GC.gc()

println("=== Profile lower_bound_filtering on $PROFILE_INSTANCE ===")
Profile.clear()
Profile.init(; n=10_000_000, delay=0.001)
t = @elapsed sol = @profile TPO.lower_bound_filtering(instance)
println("Filtering done in $(round(t; digits=2))s")

println("\n=== Flat profile, top consumers ===")
Profile.print(; format=:flat, mincount=50, sortedby=:count, noisefloor=2.0)

println("\n=== Counting hot function calls in profile ===")
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
for needle in ("update_bundle_cost_matrix", "compute_ttg_edge",
               "dijkstra_shortest_paths", "add_bundle_path",
               "remove_bundle_path", "ffd_cost",
               "incremental_cost", "tentative_bin_count",
               "lower_bound_filtering", "SparseArrays",
               "getindex")
    n = count_function(needle, data, lidict)
    pct = round(100 * n / max(total_samples, 1); digits=1)
    @printf("%-50s %8d samples (%5.1f%%)\n", needle, n, pct)
end
