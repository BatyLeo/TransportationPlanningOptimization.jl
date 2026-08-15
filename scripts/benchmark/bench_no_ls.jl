# Run inbound instances up to greedy (no local search), TPO vs STP, append
# rows to a CSV with the same per-step columns the slide-6 table reads. This
# avoids the slow LS path entirely and unblocks the world/world2..world5 rows.

using CSV, DataFrames, Dates, Printf
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using ShipperTransportationPlanning
const STP = ShipperTransportationPlanning

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")
const OUT_CSV = joinpath(@__DIR__, "results", "comparison_no_ls.csv")

const INSTANCES = ["world", "world2", "world3", "world4", "world5"]

function run_tpo_no_ls(name::String)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")
    local instance
    build_time = @elapsed begin
        (; nodes, arcs, commodities) = parse_inbound_instance(
            nodes_file, legs_file, com_file
        )
        instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    end
    local filtering_sol, sub
    filter_time = @elapsed begin
        filtering_sol = TPO.lower_bound_filtering(instance)
        sub = TPO.extract_filtered_instance(instance, filtering_sol)
    end
    local chosen
    init_time = @elapsed begin
        candidates = TPO.mix_greedy_and_lower_bound(sub)
        chosen = TPO.choose_best_feasible(
            [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
        )
    end
    init_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    init_cost = TPO.cost_with_nodes(init_full, instance)
    init_feasible = TPO.is_feasible(init_full, instance)
    return (;
        n_bundles=length(instance.bundles),
        build_time,
        filter_time,
        init_time,
        init_cost,
        init_feasible,
    )
end

function run_stp_no_ls(name::String)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")
    local instance
    build_time = @elapsed begin
        instance = STP.read_instance(nodes_file, legs_file, com_file)
        instance = STP.add_properties(instance, STP.tentative_first_fit, Int[])
    end
    local filtering_sol, sub
    filter_time = @elapsed begin
        filtering_sol = STP.Solution(instance)
        STP.lower_bound_filtering!(filtering_sol, instance)
        sub = STP.extract_filtered_instance(instance, filtering_sol)
        sub = STP.add_properties(sub, STP.tentative_first_fit, Int[])
    end
    local mix_sol
    init_time = @elapsed begin
        mix_sol = STP.Solution(sub)
        STP.mix_greedy_and_lower_bound!(mix_sol, sub)
    end
    init_full = STP.merge_solutions(mix_sol, filtering_sol, instance, sub)
    init_cost = STP.compute_cost(instance, init_full)
    init_feasible = STP.is_feasible(instance, init_full)
    return (;
        n_bundles=length(instance.bundles),
        build_time,
        filter_time,
        init_time,
        init_cost,
        init_feasible,
    )
end

function append_row(row::NamedTuple)
    df_row = DataFrame([row])
    if isfile(OUT_CSV)
        CSV.write(OUT_CSV, df_row; append=true)
    else
        CSV.write(OUT_CSV, df_row)
    end
end

println("Output: $OUT_CSV")
for name in INSTANCES
    @printf("\n=== %s ===\n", name)
    flush(stdout)
    tpo = run_tpo_no_ls(name)
    @printf(
        "TPO  bundles=%d  build=%.2fs  filter=%.2fs  init=%.2fs  cost=%.6e  feasible=%s\n",
        tpo.n_bundles,
        tpo.build_time,
        tpo.filter_time,
        tpo.init_time,
        tpo.init_cost,
        tpo.init_feasible,
    )
    flush(stdout)
    stp = run_stp_no_ls(name)
    @printf(
        "STP  bundles=%d  build=%.2fs  filter=%.2fs  init=%.2fs  cost=%.6e  feasible=%s\n",
        stp.n_bundles,
        stp.build_time,
        stp.filter_time,
        stp.init_time,
        stp.init_cost,
        stp.init_feasible,
    )
    flush(stdout)
    cost_ratio = tpo.init_cost / stp.init_cost
    append_row((;
        instance=name,
        n_bundles=tpo.n_bundles,
        tpo_build_s=round(tpo.build_time; digits=3),
        stp_build_s=round(stp.build_time; digits=3),
        tpo_filter_s=round(tpo.filter_time; digits=3),
        stp_filter_s=round(stp.filter_time; digits=3),
        tpo_init_s=round(tpo.init_time; digits=3),
        stp_init_s=round(stp.init_time; digits=3),
        tpo_init_cost=tpo.init_cost,
        stp_init_cost=stp.init_cost,
        init_cost_ratio=round(cost_ratio; digits=4),
        tpo_init_feasible=tpo.init_feasible,
        stp_init_feasible=stp.init_feasible,
    ))
    @printf("[%s] cost ratio TPO/STP = %.4f\n", name, cost_ratio)
    flush(stdout)
end
println("\nDone, rows in $OUT_CSV")
