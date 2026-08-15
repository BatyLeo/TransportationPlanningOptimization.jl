# TPO vs STP: full-pipeline performance and quality comparison.
#
# Runs each package's heuristic pipeline on the inbound benchmark instances
# and writes a side-by-side comparison of per-step costs, wall-clock times,
# and local-search throughput.
#
# This script consolidates the former compare_packages.jl, run_comparison.jl,
# step_by_step_costs_full.jl, and bench_no_ls.jl into a single entry point.
#
# Run with:
#   julia --project=scripts scripts/benchmark/compare_packages.jl
#
# Results are written incrementally to:
#   scripts/benchmark/results/comparison.csv
#   scripts/benchmark/results/comparison.md

using Dates
using Printf
using DataFrames
using CSV

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using ShipperTransportationPlanning
const STP = ShipperTransportationPlanning

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")
const OUTPUT_DIR = joinpath(@__DIR__, "results")

# Instances to compare, smallest first. Comment out large ones for a quick run.
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

# Local-search wall-clock budget (seconds). Both packages get the same budget
# on the same instance. Set to 0 to skip LS for a given instance.
const LS_TIME_LIMITS = Dict(
    "small" => 10,
    "medium" => 30,
    "large" => 60,
    "extra_large" => 120,
    "world" => 180,
    "world2" => 240,
    "world3" => 300,
    "world4" => 360,
    "world5" => 600,
)
_ls_limit(name::String) = get(LS_TIME_LIMITS, name, 60)

# Set to true to also run STP's ILS after LS (TPO has no ILS).
const INCLUDE_ILS = false
const ILS_TIME_LIMITS = Dict(name => 2 * lim for (name, lim) in LS_TIME_LIMITS)
_ils_limit(name::String) = get(ILS_TIME_LIMITS, name, 120)

# Skip instances that already have a row in the CSV (makes the script
# resumable across runs).
const SKIP_EXISTING = true

# ---------------------------------------------------------------------------
# TPO pipeline
# ---------------------------------------------------------------------------

"""
Run TPO's heuristic pipeline on instance `name` and return a NamedTuple with:
- Per-stage wall-clock times (build, filter, init, LS)
- Per-step full-instance costs (greedy, LB, mixed, init, LS)
- LS metrics (iteration count, cost saved)
- Feasibility flags (init, LS)

All costs are full-instance costs (filtered bundles merged back) via
`cost_with_nodes`. When `ls_limit <= 0`, LS is skipped and LS fields
reflect the init solution unchanged.
"""
function run_tpo(name::String, ls_limit::Real)
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

    local candidates, chosen
    init_time = @elapsed begin
        candidates = TPO.mix_greedy_and_lower_bound(sub)
        chosen = TPO.choose_best_feasible(
            [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
        )
    end

    function full_cost(sub_sol)
        return TPO.cost_with_nodes(
            TPO.merge_solutions(filtering_sol, sub_sol, instance, sub), instance
        )
    end

    greedy_cost = full_cost(candidates.greedy)
    lb_cost = full_cost(candidates.lower_bound)
    mixed_cost = full_cost(candidates.mixed)

    init_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    init_cost = TPO.cost_with_nodes(init_full, instance)
    init_feasible = TPO.is_feasible(init_full, instance)

    if ls_limit <= 0
        return (;
            n_bundles=length(instance.bundles),
            build_time,
            filter_time,
            init_time,
            greedy_cost,
            lb_cost,
            mixed_cost,
            init_cost,
            init_feasible,
            ls_cost=init_cost,
            ls_time=0.0,
            ls_feasible=init_feasible,
            ls_iters=0,
            ls_saved=0.0,
        )
    end

    local ls_result
    ls_time = @elapsed ls_result = TPO.local_search!(chosen, sub; time_limit=ls_limit)
    ls_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    ls_cost = TPO.cost_with_nodes(ls_full, instance)
    ls_feasible = TPO.is_feasible(ls_full, instance)

    return (;
        n_bundles=length(instance.bundles),
        build_time,
        filter_time,
        init_time,
        greedy_cost,
        lb_cost,
        mixed_cost,
        init_cost,
        init_feasible,
        ls_cost,
        ls_time,
        ls_feasible,
        ls_iters=ls_result.n_iter,
        ls_saved=ls_result.saved,
    )
end

# ---------------------------------------------------------------------------
# STP pipeline
# ---------------------------------------------------------------------------

"""
Run STP's heuristic pipeline on instance `name`. Returns the same fields as
`run_tpo`, plus `ils_cost` (NaN when ILS is not run).

Note: STP's `merge_solutions` takes `(sub_sol, filter_sol, instance, sub)`,
the reverse of TPO's argument order.
"""
function run_stp(name::String, ls_limit::Real; ils_limit::Real=0)
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

    local mix_sol, greedy_sol, lb_sol, chosen
    init_time = @elapsed begin
        mix_sol = STP.Solution(sub)
        greedy_sol, lb_sol = STP.mix_greedy_and_lower_bound!(mix_sol, sub)
        chosen = _stp_choose_best(mix_sol, greedy_sol, lb_sol, sub)
    end

    function full_cost(sub_sol)
        return STP.compute_cost(
            instance, STP.merge_solutions(sub_sol, filtering_sol, instance, sub)
        )
    end

    greedy_cost = full_cost(greedy_sol)
    lb_cost = full_cost(lb_sol)
    mixed_cost = full_cost(mix_sol)

    init_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    init_cost = STP.compute_cost(instance, init_full)
    init_feasible = STP.is_feasible(instance, init_full)

    if ls_limit <= 0
        return (;
            n_bundles=length(instance.bundles),
            build_time,
            filter_time,
            init_time,
            greedy_cost,
            lb_cost,
            mixed_cost,
            init_cost,
            init_feasible,
            ls_cost=init_cost,
            ls_time=0.0,
            ls_feasible=init_feasible,
            ls_iters=0,
            ls_saved=0.0,
            ils_cost=NaN,
        )
    end

    pre_ls_cost = STP.compute_cost(sub, chosen)

    # Capture STP's "Loop Break : time = X, i = Y" line from stdout.
    captured = ""
    ls_time = mktemp() do path, io
        t = @elapsed redirect_stdout(io) do
            STP.local_search!(chosen, sub; timeLimit=ls_limit, verbose=false)
        end
        flush(io)
        captured = read(path, String)
        return t
    end
    ls_iters = _parse_stp_loop_break_iters(captured)

    ls_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    ls_cost = STP.compute_cost(instance, ls_full)
    ls_feasible = STP.is_feasible(instance, ls_full)
    post_ls_cost = STP.compute_cost(sub, chosen)
    ls_saved = pre_ls_cost - post_ls_cost

    ils_cost = NaN
    if ils_limit > 0
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
    end

    return (;
        n_bundles=length(instance.bundles),
        build_time,
        filter_time,
        init_time,
        greedy_cost,
        lb_cost,
        mixed_cost,
        init_cost,
        init_feasible,
        ls_cost,
        ls_time,
        ls_feasible,
        ls_iters,
        ls_saved,
        ils_cost,
    )
end

"Pick the min-cost feasible STP solution among mixed, greedy, lower bound."
function _stp_choose_best(mix_sol, greedy_sol, lb_sol, sub)
    candidates = [mix_sol, greedy_sol, lb_sol]
    feasible = filter(s -> STP.is_feasible(sub, s), candidates)
    pool = isempty(feasible) ? candidates : feasible
    costs = [STP.compute_cost(sub, s) for s in pool]
    return STP.solution_deepcopy(pool[argmin(costs)], sub)
end

"Extract `i` from STP's `Loop Break : time = X, i = Y, noImprov = Z` log."
function _parse_stp_loop_break_iters(captured::AbstractString)
    m = match(r"Loop Break\s*:\s*time\s*=\s*[\d\.]+,\s*i\s*=\s*(\d+)", captured)
    return m === nothing ? -1 : parse(Int, m.captures[1])
end

# ---------------------------------------------------------------------------
# Result formatting
# ---------------------------------------------------------------------------

_safe_div(a, b) = b == 0 ? NaN : a / b

"Build a single-row DataFrame from one instance's TPO and STP results."
function build_row(name::String, tpo, stp)
    row = DataFrame(;
        instance=[name],
        n_bundles=[tpo.n_bundles],
        tpo_build_s=[round(tpo.build_time; digits=2)],
        stp_build_s=[round(stp.build_time; digits=2)],
        tpo_filter_s=[round(tpo.filter_time; digits=2)],
        stp_filter_s=[round(stp.filter_time; digits=2)],
        tpo_init_s=[round(tpo.init_time; digits=2)],
        stp_init_s=[round(stp.init_time; digits=2)],
        tpo_greedy_cost=[round(tpo.greedy_cost; digits=1)],
        stp_greedy_cost=[round(stp.greedy_cost; digits=1)],
        greedy_cost_ratio=[round(tpo.greedy_cost / stp.greedy_cost; digits=4)],
        tpo_lb_cost=[round(tpo.lb_cost; digits=1)],
        stp_lb_cost=[round(stp.lb_cost; digits=1)],
        lb_cost_ratio=[round(tpo.lb_cost / stp.lb_cost; digits=4)],
        tpo_mixed_cost=[round(tpo.mixed_cost; digits=1)],
        stp_mixed_cost=[round(stp.mixed_cost; digits=1)],
        mixed_cost_ratio=[round(tpo.mixed_cost / stp.mixed_cost; digits=4)],
        tpo_init_cost=[round(tpo.init_cost; digits=1)],
        stp_init_cost=[round(stp.init_cost; digits=1)],
        init_cost_ratio=[round(tpo.init_cost / stp.init_cost; digits=4)],
        tpo_ls_cost=[round(tpo.ls_cost; digits=1)],
        stp_ls_cost=[round(stp.ls_cost; digits=1)],
        ls_cost_ratio=[round(tpo.ls_cost / stp.ls_cost; digits=4)],
        tpo_ls_s=[round(tpo.ls_time; digits=2)],
        stp_ls_s=[round(stp.ls_time; digits=2)],
        tpo_ls_iters=[tpo.ls_iters],
        stp_ls_iters=[stp.ls_iters],
        tpo_ls_iter_per_s=[round(_safe_div(tpo.ls_iters, tpo.ls_time); digits=1)],
        stp_ls_iter_per_s=[round(_safe_div(stp.ls_iters, stp.ls_time); digits=1)],
        tpo_ls_saved=[round(tpo.ls_saved; digits=1)],
        stp_ls_saved=[round(stp.ls_saved; digits=1)],
        tpo_init_feasible=[tpo.init_feasible],
        stp_init_feasible=[stp.init_feasible],
        tpo_ls_feasible=[tpo.ls_feasible],
        stp_ls_feasible=[stp.ls_feasible],
    )
    if INCLUDE_ILS
        row.stp_ils_cost = [round(stp.ils_cost; digits=1)]
        row.ils_ls_ratio = [
            isnan(stp.ils_cost) ? NaN : round(stp.ils_cost / stp.ls_cost; digits=6)
        ]
    end
    return row
end

"Print a concise console summary of one instance's results."
function print_row(name::String, tpo, stp)
    @printf("\n%-12s  (%d bundles)\n", name, tpo.n_bundles)
    @printf("  %-14s %14s %14s %10s\n", "metric", "TPO", "STP", "TPO/STP")
    @printf(
        "  %-14s %14.2f %14.2f %10.2f\n",
        "build s",
        tpo.build_time,
        stp.build_time,
        tpo.build_time / stp.build_time,
    )
    @printf(
        "  %-14s %14.2f %14.2f %10.2f\n",
        "filter s",
        tpo.filter_time,
        stp.filter_time,
        tpo.filter_time / stp.filter_time,
    )
    @printf(
        "  %-14s %14.2f %14.2f %10.2f\n",
        "init s",
        tpo.init_time,
        stp.init_time,
        tpo.init_time / stp.init_time,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "greedy cost",
        tpo.greedy_cost,
        stp.greedy_cost,
        tpo.greedy_cost / stp.greedy_cost,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "LB cost",
        tpo.lb_cost,
        stp.lb_cost,
        tpo.lb_cost / stp.lb_cost,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "mixed cost",
        tpo.mixed_cost,
        stp.mixed_cost,
        tpo.mixed_cost / stp.mixed_cost,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "init cost",
        tpo.init_cost,
        stp.init_cost,
        tpo.init_cost / stp.init_cost,
    )
    if tpo.ls_iters > 0 || stp.ls_iters > 0
        @printf(
            "  %-14s %14d %14d %10.3f\n",
            "LS iters",
            tpo.ls_iters,
            stp.ls_iters,
            _safe_div(tpo.ls_iters, max(stp.ls_iters, 1)),
        )
        tpo_ips = _safe_div(tpo.ls_iters, tpo.ls_time)
        stp_ips = _safe_div(stp.ls_iters, stp.ls_time)
        @printf(
            "  %-14s %14.1f %14.1f %10.3f\n",
            "LS iter/s",
            tpo_ips,
            stp_ips,
            _safe_div(tpo_ips, max(stp_ips, 1e-9)),
        )
        @printf("  %-14s %14.1f %14.1f\n", "LS saved", tpo.ls_saved, stp.ls_saved,)
    end
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "LS cost",
        tpo.ls_cost,
        stp.ls_cost,
        tpo.ls_cost / stp.ls_cost,
    )
    if INCLUDE_ILS && !isnan(stp.ils_cost)
        @printf(
            "  %-14s %14s %14.1f %10.6f\n",
            "ILS cost",
            "n/a",
            stp.ils_cost,
            stp.ils_cost / stp.ls_cost,
        )
    end
    if !(tpo.ls_feasible && stp.ls_feasible)
        @printf(
            "  WARNING infeasible: tpo_ls=%s stp_ls=%s\n", tpo.ls_feasible, stp.ls_feasible,
        )
    end
    return nothing
end

"Render the full results DataFrame as a structured markdown report."
function write_markdown(df::DataFrame, path::String)
    open(path, "w") do io
        println(io, "# TPO vs STP Comparison")
        println(io)
        println(io, "Generated: ", Dates.now())
        println(io)
        println(io, "Ratios are TPO / STP.")
        println(io, "< 1 means TPO is cheaper or faster.")
        println(io)

        # Cost quality table.
        println(io, "## Cost Quality (TPO / STP ratio at each step)")
        println(io)
        println(io, "| Instance | Bundles | Greedy | LB | Mixed | Init | LS |")
        println(io, "|---|---|---|---|---|---|---|")
        for row in eachrow(df)
            @printf(
                io,
                "| %s | %d | %.4f | %.4f | %.4f | %.4f | %.4f |\n",
                row.instance,
                row.n_bundles,
                row.greedy_cost_ratio,
                row.lb_cost_ratio,
                row.mixed_cost_ratio,
                row.init_cost_ratio,
                row.ls_cost_ratio,
            )
        end
        println(io)

        if nrow(df) > 0
            init_gm = exp(sum(log, df.init_cost_ratio) / nrow(df))
            ls_gm = exp(sum(log, df.ls_cost_ratio) / nrow(df))
            @printf(io, "Geometric-mean init-cost ratio: **%.4f**\n", init_gm)
            println(io)
            @printf(io, "Geometric-mean LS-cost ratio: **%.4f**\n", ls_gm)
            println(io)
        end

        # Timing table.
        println(io, "## Timing (seconds)")
        println(io)
        println(
            io,
            "| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |",
        )
        println(io, "|---|---|---|---|---|---|---|")
        for row in eachrow(df)
            @printf(
                io,
                "| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |\n",
                row.instance,
                row.tpo_build_s,
                row.stp_build_s,
                row.tpo_filter_s,
                row.stp_filter_s,
                row.tpo_init_s,
                row.stp_init_s,
            )
        end
        println(io)

        # LS throughput table.
        ls_rows = filter(
            row -> row.tpo_ls_iters > 0 || row.stp_ls_iters > 0, collect(eachrow(df))
        )
        if !isempty(ls_rows)
            println(io, "## Local Search Throughput")
            println(io)
            println(
                io, "| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |"
            )
            println(io, "|---|---|---|---|---|---|")
            for row in ls_rows
                ratio = _safe_div(row.tpo_ls_iter_per_s, max(row.stp_ls_iter_per_s, 1e-9))
                @printf(
                    io,
                    "| %s | %d | %d | %.1f | %.1f | %.3f |\n",
                    row.instance,
                    row.tpo_ls_iters,
                    row.stp_ls_iters,
                    row.tpo_ls_iter_per_s,
                    row.stp_ls_iter_per_s,
                    ratio,
                )
            end
            println(io)
        end

        # ILS section.
        if INCLUDE_ILS && hasproperty(df, :stp_ils_cost)
            println(io, "## STP ILS vs LS")
            println(io)
            println(io, "| Instance | STP LS cost | STP ILS cost | ILS / LS |")
            println(io, "|---|---|---|---|")
            for row in eachrow(df)
                isnan(row.stp_ils_cost) && continue
                @printf(
                    io,
                    "| %s | %.1f | %.1f | %.6f |\n",
                    row.instance,
                    row.stp_ls_cost,
                    row.stp_ils_cost,
                    row.ils_ls_ratio,
                )
            end
            println(io)
        end

        # Feasibility warnings.
        infeasible = filter(
            row -> !(row.tpo_ls_feasible && row.stp_ls_feasible), collect(eachrow(df))
        )
        if !isempty(infeasible)
            println(io, "## Feasibility Warnings")
            println(io)
            for row in infeasible
                @printf(
                    io,
                    "- **%s**: tpo_ls=%s, stp_ls=%s\n",
                    row.instance,
                    row.tpo_ls_feasible,
                    row.stp_ls_feasible,
                )
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

"""
Run the comparison over all configured instances.

Writes CSV and markdown after each instance so partial progress survives a
crash. Pass `ls_limit_override` to use the same LS budget for every instance
(useful for quick passes).
"""
function compare_all(; ls_limit_override::Union{Nothing,Real}=nothing)
    isdir(OUTPUT_DIR) || mkpath(OUTPUT_DIR)
    csv_path = joinpath(OUTPUT_DIR, "comparison.csv")
    md_path = joinpath(OUTPUT_DIR, "comparison.md")

    df = if SKIP_EXISTING && isfile(csv_path)
        loaded = DataFrame(CSV.File(csv_path))
        if "greedy_cost_ratio" in names(loaded)
            loaded
        else
            @warn "Existing CSV uses old schema, starting fresh"
            DataFrame()
        end
    else
        DataFrame()
    end
    done = nrow(df) > 0 ? Set(string.(df.instance)) : Set{String}()

    if !isempty(INSTANCES)
        @info "JIT warmup on $(first(INSTANCES)) (timings discarded)"
        try
            run_tpo(first(INSTANCES), 1)
            run_stp(first(INSTANCES), 1)
        catch err
            @warn "Warmup failed" exception = err
        end
        GC.gc()
    end

    for name in INSTANCES
        if name in done
            @info "Skipping $name (already in CSV)"
            continue
        end
        ls_limit = ls_limit_override === nothing ? _ls_limit(name) : ls_limit_override
        ils_limit = INCLUDE_ILS ? _ils_limit(name) : 0
        @info "Running $name" ls_limit ils_limit
        local tpo, stp
        try
            tpo = run_tpo(name, ls_limit)
            GC.gc()
            stp = run_stp(name, ls_limit; ils_limit)
            GC.gc()
        catch err
            @error "Instance $name failed, skipping" exception = (err, catch_backtrace())
            continue
        end
        print_row(name, tpo, stp)
        df = vcat(df, build_row(name, tpo, stp))
        CSV.write(csv_path, df)
        write_markdown(df, md_path)
        @info "Wrote results through $name"
    end

    println("\n", "="^60)
    println("Comparison complete. Results in:")
    println("  ", csv_path)
    println("  ", md_path)
    return df
end

if abspath(PROGRAM_FILE) == @__FILE__
    compare_all()
end
