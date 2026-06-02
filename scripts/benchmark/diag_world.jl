# Stage-by-stage timing of the `world` inbound instance, TPO vs STP, to diagnose
# why the full sweep stalls on world. Prints each stage as it finishes.
using Dates, Printf
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using ShipperTransportationPlanning
const STP = ShipperTransportationPlanning

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")
name = get(ARGS, 1, "world")

nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")

println("=== $name : TPO stages ===")
flush(stdout)
t = @elapsed (; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
@printf("TPO parse:    %.2f s\n", t); flush(stdout)
t = @elapsed inst = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
@printf("TPO build:    %.2f s  (%d bundles)\n", t, length(inst.bundles)); flush(stdout)
t = @elapsed fsol = TPO.lower_bound_filtering(inst)
@printf("TPO filter:   %.2f s\n", t); flush(stdout)
t = @elapsed sub = TPO.extract_filtered_instance(inst, fsol)
@printf("TPO extract:  %.2f s\n", t); flush(stdout)
t = @elapsed cand = TPO.mix_greedy_and_lower_bound(sub)
@printf("TPO mix:      %.2f s\n", t); flush(stdout)

# pick best feasible candidate, then run LS with the same 180s budget the sweep uses
chosen = TPO.choose_best_feasible([cand.mixed, cand.greedy, cand.lower_bound], sub)
t = @elapsed TPO.local_search!(chosen, sub; time_limit=180)
@printf("TPO LS (180s budget actual): %.2f s\n", t); flush(stdout)
t = @elapsed merged = TPO.merge_solutions(fsol, chosen, inst, sub)
@printf("TPO merge:    %.2f s\n", t); flush(stdout)
t = @elapsed c = TPO.cost_with_nodes(merged, inst)
@printf("TPO cost_with_nodes: %.2f s  (cost=%.6e)\n", t, c); flush(stdout)
t = @elapsed f = TPO.is_feasible(merged, inst)
@printf("TPO is_feasible:     %.2f s  (feasible=%s)\n", t, f); flush(stdout)

println("\n=== $name : STP stages ===")
flush(stdout)
t = @elapsed begin
    stp_inst = STP.read_instance(nodes_file, legs_file, com_file)
    stp_inst = STP.add_properties(stp_inst, STP.tentative_first_fit, Int[])
end
@printf("STP build:    %.2f s\n", t); flush(stdout)
t = @elapsed begin
    stp_fsol = STP.Solution(stp_inst)
    STP.lower_bound_filtering!(stp_fsol, stp_inst)
    stp_sub = STP.extract_filtered_instance(stp_inst, stp_fsol)
    stp_sub = STP.add_properties(stp_sub, STP.tentative_first_fit, Int[])
end
@printf("STP filter:   %.2f s\n", t); flush(stdout)
t = @elapsed begin
    stp_mix = STP.Solution(stp_sub)
    STP.mix_greedy_and_lower_bound!(stp_mix, stp_sub)
end
@printf("STP mix:      %.2f s\n", t); flush(stdout)
