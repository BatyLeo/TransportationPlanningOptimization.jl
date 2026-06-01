# Step-by-step cost comparison: TPO vs STP.
#
# Reports the cost of the solution after each pipeline step:
#   1. Greedy candidate (from mix)
#   2. Lower-bound candidate (from mix)
#   3. Mixed candidate
#   4. Chosen initial solution (best of the three)
#   5. After local search
#   6. After ILS  (STP only; TPO does not implement ILS yet)
#
# Pipeline matches `run_comparison.jl`: filter, extract sub, mix on sub,
# local_search on sub, then ILS on sub for STP. Costs are reported on the
# full instance after `merge_solutions(filter_sol, sub_sol)` (or the
# equivalent STP step).
include(joinpath(@__DIR__, "compare_packages.jl"))

using Printf, Dates

const INSTANCES = ["small", "medium", "large"]
const LS_LIMITS = Dict("small" => 10, "medium" => 30, "large" => 60)
const ILS_LIMITS = Dict("small" => 60, "medium" => 180, "large" => 300)

"""
Run TPO's full pipeline on `name`. Returns the cost at each milestone (each
reported as the full-instance cost via merge + `cost_with_nodes`).
"""
function tpo_pipeline(name::String, ls_limit::Real)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")

    (; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
    instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    filtering_sol = TPO.lower_bound_filtering(instance)
    sub = TPO.extract_filtered_instance(instance, filtering_sol)
    candidates = TPO.mix_greedy_and_lower_bound(sub)

    # Cost each candidate by merging back to full instance.
    function full_cost(sub_sol)
        return TPO.cost_with_nodes(
            TPO.merge_solutions(filtering_sol, sub_sol, instance, sub), instance
        )
    end

    greedy_cost = full_cost(candidates.greedy)
    lb_cost = full_cost(candidates.lower_bound)
    mixed_cost = full_cost(candidates.mixed)

    chosen = TPO.choose_best_feasible(
        [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
    )
    init_cost = full_cost(chosen)

    TPO.local_search!(chosen, sub; time_limit=ls_limit)
    ls_cost = full_cost(chosen)

    return (; greedy_cost, lb_cost, mixed_cost, init_cost, ls_cost)
end

"""
Run STP's full pipeline on `name`. Returns cost at each milestone, including
ILS. The ILS runs for `ils_limit` seconds; perturbation budget is
`min(180, ils_limit / 5)` and per-LS budget is `min(2700, ils_limit)`
(matches the recipe used by `julia_main_test`).
"""
function stp_pipeline(name::String, ls_limit::Real, ils_limit::Real)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")

    instance = STP.read_instance(nodes_file, legs_file, com_file)
    instance = STP.add_properties(instance, STP.tentative_first_fit, Int[])

    filtering_sol = STP.Solution(instance)
    STP.lower_bound_filtering!(filtering_sol, instance)
    sub = STP.extract_filtered_instance(instance, filtering_sol)
    sub = STP.add_properties(sub, STP.tentative_first_fit, Int[])

    mix_sol = STP.Solution(sub)
    greedy_sol, lb_sol = STP.mix_greedy_and_lower_bound!(mix_sol, sub)

    # STP merge order is (sub_sol, filter_sol, instance, sub).
    function full_cost(sub_sol)
        return STP.compute_cost(
            instance, STP.merge_solutions(sub_sol, filtering_sol, instance, sub)
        )
    end

    greedy_cost = full_cost(greedy_sol)
    lb_cost = full_cost(lb_sol)
    mixed_cost = full_cost(mix_sol)

    feasibles = [s for s in (mix_sol, greedy_sol, lb_sol) if STP.is_feasible(sub, s)]
    pool = isempty(feasibles) ? [mix_sol, greedy_sol, lb_sol] : feasibles
    chosen = STP.solution_deepcopy(
        pool[argmin(STP.compute_cost(sub, s) for s in pool)], sub
    )
    init_cost = full_cost(chosen)

    # Local search.
    captured = ""
    mktemp() do path, io
        redirect_stdout(io) do
            STP.local_search!(chosen, sub; timeLimit=Int(ls_limit), verbose=false)
        end
        flush(io)
        captured = read(path, String)
    end
    ls_cost = full_cost(chosen)

    # ILS.
    pert_limit = round(Int, min(180.0, ils_limit / 5))
    inner_ls = round(Int, min(2700.0, ils_limit))
    mktemp() do path, io
        redirect_stdout(io) do
            STP.ILS!(
                chosen,
                sub;
                timeLimit=Int(ils_limit),
                perturbTimeLimit=pert_limit,
                lsTimeLimit=inner_ls,
                verbose=false,
                solName=name,
                timedelta=inner_ls,
            )
        end
        flush(io)
        captured *= read(path, String)
    end
    ils_cost = full_cost(chosen)

    return (; greedy_cost, lb_cost, mixed_cost, init_cost, ls_cost, ils_cost)
end

println("=== Warmup (TPO + STP on small, results discarded) ===")
tpo_pipeline("small", 1)
stp_pipeline("small", 1, 5)
GC.gc()
println("=== Warmup done ===\n")

results = Dict{String,Any}()
for name in INSTANCES
    lsl = LS_LIMITS[name]
    ilsl = ILS_LIMITS[name]
    println("\n", "="^70)
    println("=== $name  (LS budget = $(lsl)s, ILS budget = $(ilsl)s) ===")
    println("="^70)

    println("--- TPO pipeline ---")
    flush(stdout)
    tpo = tpo_pipeline(name, lsl)
    GC.gc()
    println("--- STP pipeline (incl. ILS) ---")
    flush(stdout)
    stp = stp_pipeline(name, lsl, ilsl)
    GC.gc()

    results[name] = (; tpo, stp)

    @printf("\n%-12s %18s %18s %12s\n", "Step", "TPO cost", "STP cost", "TPO/STP")
    println(repeat('-', 64))
    @printf(
        "%-12s %18.1f %18.1f %12.4f\n",
        "greedy",
        tpo.greedy_cost,
        stp.greedy_cost,
        tpo.greedy_cost / stp.greedy_cost
    )
    @printf(
        "%-12s %18.1f %18.1f %12.4f\n",
        "lower_bound",
        tpo.lb_cost,
        stp.lb_cost,
        tpo.lb_cost / stp.lb_cost
    )
    @printf(
        "%-12s %18.1f %18.1f %12.4f\n",
        "mixed",
        tpo.mixed_cost,
        stp.mixed_cost,
        tpo.mixed_cost / stp.mixed_cost
    )
    @printf(
        "%-12s %18.1f %18.1f %12.4f\n",
        "init (best)",
        tpo.init_cost,
        stp.init_cost,
        tpo.init_cost / stp.init_cost
    )
    @printf(
        "%-12s %18.1f %18.1f %12.4f\n",
        "LS",
        tpo.ls_cost,
        stp.ls_cost,
        tpo.ls_cost / stp.ls_cost
    )
    @printf("%-12s %18s %18.1f %12s\n", "ILS", "n/a", stp.ils_cost, "—")
    println()
end

println("\n", "="^70)
println("=== Summary (all instances, ratios = TPO / STP) ===")
println("="^70)
@printf(
    "%-12s %12s %12s %12s %12s %12s %12s\n",
    "instance",
    "greedy",
    "lower_b.",
    "mixed",
    "init",
    "LS",
    "STP ILS"
)
for name in INSTANCES
    r = results[name]
    @printf(
        "%-12s %12.4f %12.4f %12.4f %12.4f %12.4f %12.1f\n",
        name,
        r.tpo.greedy_cost / r.stp.greedy_cost,
        r.tpo.lb_cost / r.stp.lb_cost,
        r.tpo.mixed_cost / r.stp.mixed_cost,
        r.tpo.init_cost / r.stp.init_cost,
        r.tpo.ls_cost / r.stp.ls_cost,
        r.stp.ils_cost,
    )
end
