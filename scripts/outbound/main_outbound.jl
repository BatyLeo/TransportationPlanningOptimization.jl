using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
include("Outbound.jl")
using .Outbound

using DataFrames
using CSV
using Dates

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "outbound", "dataMVP")

(; nodes, arcs, commodities) = Outbound.parse_dataMVP_instance(
    DATA_DIR; keep_modes=true, all_linear=true
)

# `group_by = c -> c.info.model` puts one bundle per (origin, destination, model).
# This is a non-default grouping: several bundles can share an (origin, destination)
# pair and differ only by model. `merge_solutions` keys on (origin, destination,
# group), so the filter -> extract -> merge decomposition below disambiguates them.
instance = Instance(
    nodes,
    arcs,
    commodities,
    Day(30);
    wrap_time=false,
    allow_multimodal=true,
    group_by=c -> c.info.model,
)
println(
    "MVP-MULTI Instance: $(length(nodes)) nodes, $(length(arcs)) arcs, " *
    "$(length(commodities)) commodities, $(bundle_count(instance)) bundles",
)

# Direct greedy baseline on the full instance.
t_greedy = @elapsed sol = greedy_heuristic(instance)
println("MVP-MULTI Greedy (full): cost=$(cost(sol)) time=$(round(t_greedy; digits=2))s")

# Decomposition pipeline (mirrors scripts/inbound/main_inbound.jl):
# lower-bound filtering -> extract the non-direct sub-instance -> solve the
# sub-instance -> stitch back onto the full instance.
t_filter = @elapsed filtering_sol = lower_bound_filtering(instance)
sub_instance = TPO.extract_filtered_instance(instance, filtering_sol)
println(
    "MVP-MULTI Filter: $(bundle_count(sub_instance)) sub-bundles kept " *
    "time=$(round(t_filter; digits=2))s",
)

t_sub = @elapsed sub_sol = greedy_heuristic(sub_instance)
t_merge = @elapsed full_solution = TPO.merge_solutions(
    filtering_sol, sub_sol, instance, sub_instance
)

feasible = is_feasible(full_solution, instance; verbose=true)
println(
    "MVP-MULTI Decomposed: cost=$(cost(full_solution)) feasible=$(feasible) " *
    "sub_solve=$(round(t_sub; digits=2))s merge=$(round(t_merge; digits=2))s",
)
