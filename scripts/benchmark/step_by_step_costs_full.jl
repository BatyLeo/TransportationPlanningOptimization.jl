# Full step-by-step cost comparison: TPO vs STP across all instances.
#
# Same logic as `step_by_step_costs.jl` but extended to extra_large and the
# five world instances. Writes a single markdown report incrementally
# (`scripts/benchmark/results/step_by_step_costs.md`) so partial results
# survive a crash or interrupt.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Printf, Dates

const INSTANCES = [
    "small",
    "medium",
    "large",
    "extra_large",
    "world",
    "world2",
    "world3",
    "world4",
    "world5",
]

# LS time scales with instance complexity; ILS = 2 * LS by STP convention.
const LS_LIMITS = Dict(
    "small" => 10,
    "medium" => 30,
    "large" => 60,
    "extra_large" => 120,
    "world" => 180,
    "world2" => 180,
    "world3" => 180,
    "world4" => 180,
    "world5" => 180,
)
const ILS_LIMITS = Dict(name => 2 * lim for (name, lim) in LS_LIMITS)

const OUT_MD = joinpath(@__DIR__, "results", "step_by_step_costs.md")

"""
Run TPO's full pipeline on `name`. Returns the cost at each milestone (full-
instance cost via merge + `cost_with_nodes`).
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

"Run STP's full pipeline incl. ILS. Returns cost at each milestone."
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

    # LS (suppress stdout chatter).
    mktemp() do path, io
        redirect_stdout(io) do
            STP.local_search!(chosen, sub; timeLimit=Int(ls_limit), verbose=false)
        end
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
    end
    ils_cost = full_cost(chosen)

    return (; greedy_cost, lb_cost, mixed_cost, init_cost, ls_cost, ils_cost)
end

"Write the markdown report from collected results."
function write_report(results::Dict)
    open(OUT_MD, "w") do io
        println(io, "# TPO vs STP — step-by-step cost comparison")
        println(io)
        println(io, "Generated: ", Dates.now())
        println(io)
        println(io, "All costs are full-instance costs (filtered + sub merged back).")
        println(io, "Ratios are TPO / STP. < 1 means TPO is cheaper.")
        println(io)

        # Per-instance detailed tables.
        for name in INSTANCES
            haskey(results, name) || continue
            r = results[name]
            lsl = LS_LIMITS[name]
            ilsl = ILS_LIMITS[name]
            println(io, "## $name  (LS $(lsl)s, ILS $(ilsl)s)")
            println(io)
            println(io, "| Step | TPO cost | STP cost | TPO / STP |")
            println(io, "|---|---|---|---|")
            @printf(
                io,
                "| greedy candidate | %.1f | %.1f | %.4f |\n",
                r.tpo.greedy_cost,
                r.stp.greedy_cost,
                r.tpo.greedy_cost / r.stp.greedy_cost
            )
            @printf(
                io,
                "| lower-bound candidate | %.1f | %.1f | %.4f |\n",
                r.tpo.lb_cost,
                r.stp.lb_cost,
                r.tpo.lb_cost / r.stp.lb_cost
            )
            @printf(
                io,
                "| mixed candidate | %.1f | %.1f | %.4f |\n",
                r.tpo.mixed_cost,
                r.stp.mixed_cost,
                r.tpo.mixed_cost / r.stp.mixed_cost
            )
            @printf(
                io,
                "| **init (best of 3)** | **%.1f** | **%.1f** | **%.4f** |\n",
                r.tpo.init_cost,
                r.stp.init_cost,
                r.tpo.init_cost / r.stp.init_cost
            )
            @printf(
                io,
                "| **after LS** | **%.1f** | **%.1f** | **%.4f** |\n",
                r.tpo.ls_cost,
                r.stp.ls_cost,
                r.tpo.ls_cost / r.stp.ls_cost
            )
            @printf(io, "| **after STP ILS** | n/a | **%.1f** | — |\n", r.stp.ils_cost)
            println(io)
        end

        # Summary table.
        println(io, "## Summary — TPO/STP ratios at each step")
        println(io)
        println(io, "| instance | greedy | lower_b. | mixed | init | LS | (STP ILS abs) |")
        println(io, "|---|---|---|---|---|---|---|")
        for name in INSTANCES
            haskey(results, name) || continue
            r = results[name]
            @printf(
                io,
                "| %s | %.4f | %.4f | %.4f | %.4f | %.4f | %.1f |\n",
                name,
                r.tpo.greedy_cost / r.stp.greedy_cost,
                r.tpo.lb_cost / r.stp.lb_cost,
                r.tpo.mixed_cost / r.stp.mixed_cost,
                r.tpo.init_cost / r.stp.init_cost,
                r.tpo.ls_cost / r.stp.ls_cost,
                r.stp.ils_cost,
            )
        end
        println(io)

        # STP LS vs STP ILS, to see if ILS actually improves anything.
        println(io, "## STP only — does ILS improve over LS?")
        println(io)
        println(io, "| instance | LS cost | ILS cost | ILS / LS |")
        println(io, "|---|---|---|---|")
        for name in INSTANCES
            haskey(results, name) || continue
            r = results[name]
            @printf(
                io,
                "| %s | %.1f | %.1f | %.6f |\n",
                name,
                r.stp.ls_cost,
                r.stp.ils_cost,
                r.stp.ils_cost / r.stp.ls_cost
            )
        end
    end
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
    println("=== $name  (LS = $(lsl)s, ILS = $(ilsl)s) ===  $(Dates.now())")
    println("="^70)

    println("--- TPO pipeline ---")
    flush(stdout)
    t0 = time()
    tpo = tpo_pipeline(name, lsl)
    println("    TPO pipeline took $(round(time() - t0; digits=1))s")
    GC.gc()

    println("--- STP pipeline (incl. ILS) ---")
    flush(stdout)
    t0 = time()
    stp = stp_pipeline(name, lsl, ilsl)
    println("    STP pipeline took $(round(time() - t0; digits=1))s")
    GC.gc()

    results[name] = (; tpo, stp)
    write_report(results)
    @printf(
        "✓ %s done. TPO ls=%.1f, STP ls=%.1f, STP ils=%.1f (ratio LS=%.4f, ILS/LS=%.6f)\n",
        name,
        tpo.ls_cost,
        stp.ls_cost,
        stp.ils_cost,
        tpo.ls_cost / stp.ls_cost,
        stp.ils_cost / stp.ls_cost
    )
    flush(stdout)
end

println("\n\n=== ALL DONE — final report at $OUT_MD ===")
