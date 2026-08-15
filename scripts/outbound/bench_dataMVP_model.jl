using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using Dates
include(joinpath(@__DIR__, "Outbound.jl"))
using .Outbound

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "outbound", "dataMVP")
const HEXALY = 19_569_213.0   # solver route accounting (== model-aware re-cost)

flush(stdout)
t_parse = @elapsed (; nodes, arcs, commodities) = Outbound.parse_dataMVP_instance(
    DATA_DIR; model_costs=true
)
println(
    "parse: $(round(t_parse;digits=1))s  nodes=$(length(nodes)) arcs=$(length(arcs)) commodities=$(length(commodities))",
)
flush(stdout)

t_inst = @elapsed instance = Instance(
    nodes,
    arcs,
    commodities,
    Day(600);
    wrap_time=false,
    allow_multimodal=true,
    group_by=c -> c.info.model,   # one bundle per (origin, destination, model)
)
println("instance: $(round(t_inst;digits=1))s  bundles=$(bundle_count(instance))")
flush(stdout)

selector = CheapestMode()   # capacities are all non-binding, so spill is inert here
t_greedy = @elapsed sol = greedy_heuristic(instance; mode_selector=selector)
cg = cost(sol)
println(
    "greedy: cost=$(round(cg;digits=0))  time=$(round(t_greedy;digits=1))s  gap_vs_hexaly=$(round(100*(cg-HEXALY)/HEXALY;digits=2))%",
)
flush(stdout)

ls_info = nothing
t_ls = @elapsed (ls_info = local_search!(sol, instance, selector; time_limit=180.0))
cl = cost(sol)
println(
    "local_search: cost=$(round(cl;digits=0))  time=$(round(t_ls;digits=1))s  iter=$(ls_info.n_iter)  no_improv=$(ls_info.n_no_improv)  saved=$(round(ls_info.saved;digits=2))  gap_vs_hexaly=$(round(100*(cl-HEXALY)/HEXALY;digits=2))%",
)
flush(stdout)

println("\n=== SUMMARY ===")
println("Hexaly (route accounting): $(round(HEXALY;digits=0))")
println(
    "TPO greedy               : $(round(cg;digits=0))  ($(round(100*(cg-HEXALY)/HEXALY;digits=2))%)",
)
println(
    "TPO greedy+LS            : $(round(cl;digits=0))  ($(round(100*(cl-HEXALY)/HEXALY;digits=2))%)",
)
