# Profile TPO local_search! on the `world` inbound instance to find the hot
# path responsible for the LS slowdown. Loads up through `mix`, then samples
# `local_search!` with a short budget and prints top hot functions by self-time
# (inner loop) and by total time (broader stack share).

using Printf, Profile
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")
name = get(ARGS, 1, "world")
budget_s = parse(Float64, get(ARGS, 2, "60"))

nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")

println("=== $name : setup ==="); flush(stdout)
t = @elapsed (; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
@printf("parse:    %.2f s\n", t); flush(stdout)
t = @elapsed inst = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
@printf("build:    %.2f s  (%d bundles)\n", t, length(inst.bundles)); flush(stdout)
t = @elapsed fsol = TPO.lower_bound_filtering(inst)
@printf("filter:   %.2f s\n", t); flush(stdout)
t = @elapsed sub = TPO.extract_filtered_instance(inst, fsol)
@printf("extract:  %.2f s\n", t); flush(stdout)
t = @elapsed cand = TPO.mix_greedy_and_lower_bound(sub)
@printf("mix:      %.2f s\n", t); flush(stdout)
chosen = TPO.choose_best_feasible([cand.mixed, cand.greedy, cand.lower_bound], sub)

# ~10M samples cap, 10ms between samples = up to ~28h of profiling, plenty.
Profile.init(; n=10_000_000, delay=0.01)
Profile.clear()

println("\n=== profiling local_search! for $(budget_s)s ==="); flush(stdout)
ls_t = @elapsed @profile TPO.local_search!(chosen, sub; time_limit=budget_s)
@printf("LS wall time: %.2f s\n\n", ls_t); flush(stdout)

println("=== TOP 40 by SELF time (inner loop hotspots) ===")
buf = IOBuffer()
Profile.print(buf; format=:flat, sortedby=:count, mincount=50)
println(String(take!(buf))[1:min(end, 12_000)])

println("\n=== TOP 30 by TOTAL time (where time goes, tree view) ===")
buf = IOBuffer()
Profile.print(buf; format=:tree, mincount=200, maxdepth=20)
println(String(take!(buf))[1:min(end, 12_000)])
