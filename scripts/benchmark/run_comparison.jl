# Benchmark driver. Reuses `compare_packages.jl` for everything except the
# local-search step, which we override here to also capture iteration counts:
# both packages run LS to a wall-clock budget, so wall-clock time is not
# informative — what matters is iterations completed and cost saved.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Dates, Printf, DataFrames, CSV

# ---------------------------------------------------------------------------
# Per-package one-instance pipelines (filter -> mix -> LS), recording iter
# counts and saved cost for the LS phase.
# ---------------------------------------------------------------------------

"Run TPO's full pipeline on `name`, with LS metrics (iter count, saved cost)."
function run_tpo_with_iters(name::String, ls_limit::Real)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")

    local instance
    build_time = @elapsed begin
        (; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
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

    local ls_result
    ls_time = @elapsed ls_result = TPO.local_search!(chosen, sub; time_limit=ls_limit)
    ls_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    ls_cost = TPO.cost_with_nodes(ls_full, instance)
    ls_feasible = TPO.is_feasible(ls_full, instance)

    return (;
        n_bundles=length(instance.bundles),
        build_time, filter_time,
        init_cost, init_time, init_feasible,
        ls_cost, ls_time, ls_feasible,
        ls_iters=ls_result.n_iter,
        ls_saved=ls_result.saved,
    )
end

"""
Run STP's full pipeline on `name`, with LS metrics. STP doesn't expose iteration
count from its `local_search!` return value; we capture it from the
`Loop Break : time = X, i = Y, noImprov = Z` line that STP prints to stdout.
"""
function run_stp_with_iters(name::String, ls_limit::Real)
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

    local chosen
    init_time = @elapsed begin
        mix_sol = STP.Solution(sub)
        greedy_sol, lb_sol = STP.mix_greedy_and_lower_bound!(mix_sol, sub)
        chosen = _stp_choose_best(mix_sol, greedy_sol, lb_sol, sub)
    end
    init_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    init_cost = STP.compute_cost(instance, init_full)
    init_feasible = STP.is_feasible(instance, init_full)

    # Cost before LS so we can compute saved cost (STP's return is totImprov
    # which we could use, but capturing pre/post is more uniform with TPO).
    pre_ls_cost = STP.compute_cost(sub, chosen)

    # Capture STP's "Loop Break : time = X, i = Y, noImprov = Z" line.
    captured = ""
    ls_time = mktemp() do path, io
        t = @elapsed redirect_stdout(io) do
            STP.local_search!(chosen, sub; timeLimit=ls_limit, verbose=false)
        end
        flush(io)
        captured = read(path, String)
        return t
    end
    ls_iters = parse_stp_loop_break_iters(captured)

    ls_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    ls_cost = STP.compute_cost(instance, ls_full)
    ls_feasible = STP.is_feasible(instance, ls_full)
    post_ls_cost = STP.compute_cost(sub, chosen)

    return (;
        n_bundles=length(instance.bundles),
        build_time, filter_time,
        init_cost, init_time, init_feasible,
        ls_cost, ls_time, ls_feasible,
        ls_iters,
        ls_saved=pre_ls_cost - post_ls_cost,
    )
end

"Extract `i` from STP's `Loop Break : time = X, i = Y, noImprov = Z` log line."
function parse_stp_loop_break_iters(captured::AbstractString)
    m = match(r"Loop Break\s*:\s*time\s*=\s*[\d\.]+,\s*i\s*=\s*(\d+)", captured)
    return m === nothing ? -1 : parse(Int, m.captures[1])
end

# ---------------------------------------------------------------------------
# Row builder / printer with the new LS metrics
# ---------------------------------------------------------------------------

function build_row_iters(name::String, tpo, stp)
    return DataFrame(;
        instance=[name],
        n_bundles=[tpo.n_bundles],
        tpo_build_s=[round(tpo.build_time; digits=2)],
        stp_build_s=[round(stp.build_time; digits=2)],
        tpo_filter_s=[round(tpo.filter_time; digits=2)],
        stp_filter_s=[round(stp.filter_time; digits=2)],
        tpo_init_cost=[round(tpo.init_cost; digits=1)],
        stp_init_cost=[round(stp.init_cost; digits=1)],
        init_cost_ratio=[round(tpo.init_cost / stp.init_cost; digits=4)],
        tpo_init_s=[round(tpo.init_time; digits=2)],
        stp_init_s=[round(stp.init_time; digits=2)],
        tpo_ls_cost=[round(tpo.ls_cost; digits=1)],
        stp_ls_cost=[round(stp.ls_cost; digits=1)],
        ls_cost_ratio=[round(tpo.ls_cost / stp.ls_cost; digits=4)],
        tpo_ls_s=[round(tpo.ls_time; digits=2)],
        stp_ls_s=[round(stp.ls_time; digits=2)],
        tpo_ls_iters=[tpo.ls_iters],
        stp_ls_iters=[stp.ls_iters],
        tpo_ls_iter_per_s=[round(tpo.ls_iters / tpo.ls_time; digits=1)],
        stp_ls_iter_per_s=[round(stp.ls_iters / stp.ls_time; digits=1)],
        tpo_ls_saved=[round(tpo.ls_saved; digits=1)],
        stp_ls_saved=[round(stp.ls_saved; digits=1)],
        tpo_init_feasible=[tpo.init_feasible],
        stp_init_feasible=[stp.init_feasible],
        tpo_ls_feasible=[tpo.ls_feasible],
        stp_ls_feasible=[stp.ls_feasible],
    )
end

function print_row_iters(name::String, tpo, stp)
    @printf("\n%-12s  (%d bundles)\n", name, tpo.n_bundles)
    @printf("  %-12s %14s %14s %10s\n", "stage", "TPO", "STP", "TPO/STP")
    @printf("  %-12s %14.2f %14.2f %10.2f\n", "build s", tpo.build_time, stp.build_time, tpo.build_time / stp.build_time)
    @printf("  %-12s %14.2f %14.2f %10.2f\n", "filter s", tpo.filter_time, stp.filter_time, tpo.filter_time / stp.filter_time)
    @printf("  %-12s %14.2f %14.2f %10.2f\n", "init s", tpo.init_time, stp.init_time, tpo.init_time / stp.init_time)
    @printf("  %-12s %14.1f %14.1f %10.4f\n", "init cost", tpo.init_cost, stp.init_cost, tpo.init_cost / stp.init_cost)
    @printf("  %-12s %14d %14d %10.3f\n", "LS iters", tpo.ls_iters, stp.ls_iters, tpo.ls_iters / max(stp.ls_iters, 1))
    @printf("  %-12s %14.1f %14.1f %10.3f\n", "LS iter/s", tpo.ls_iters / tpo.ls_time, stp.ls_iters / stp.ls_time, (tpo.ls_iters / tpo.ls_time) / max(stp.ls_iters / stp.ls_time, 1e-9))
    @printf("  %-12s %14.1f %14.1f %10.4f\n", "LS saved", tpo.ls_saved, stp.ls_saved, tpo.ls_saved / max(abs(stp.ls_saved), 1.0))
    @printf("  %-12s %14.1f %14.1f %10.4f\n", "LS final", tpo.ls_cost, stp.ls_cost, tpo.ls_cost / stp.ls_cost)
    if !(tpo.ls_feasible && stp.ls_feasible)
        @printf("  WARNING infeasible: tpo_ls=%s stp_ls=%s\n", tpo.ls_feasible, stp.ls_feasible)
    end
    return nothing
end

function write_markdown_iters(df::DataFrame, path::String)
    open(path, "w") do io
        println(io, "# TPO vs STP full-pipeline comparison (with LS iter counts)")
        println(io)
        println(io, "Generated: ", Dates.now())
        println(io)
        println(io, "Ratios are TPO / STP (< 1 means TPO is cheaper / faster / does more).")
        println(io)
        cols = names(df)
        println(io, "| " * join(cols, " | ") * " |")
        println(io, "| " * join(fill("---", length(cols)), " | ") * " |")
        for row in eachrow(df)
            println(io, "| " * join((string(row[c]) for c in cols), " | ") * " |")
        end
        if nrow(df) > 0
            init_geomean = exp(sum(log, df.init_cost_ratio) / nrow(df))
            ls_geomean = exp(sum(log, df.ls_cost_ratio) / nrow(df))
            println(io)
            println(io, "## Summary")
            println(io)
            @printf(io, "- Geometric-mean init-cost ratio (TPO/STP): %.4f\n", init_geomean)
            @printf(io, "- Geometric-mean LS-cost ratio (TPO/STP): %.4f\n", ls_geomean)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

function run_comparison()
    instances = ["small", "medium", "large"]  # extra_large skipped (STP filter ~30+ min)
    ls_limits = Dict("small" => 10, "medium" => 30, "large" => 60, "extra_large" => 120)

    println("=== JIT warmup on small (timings discarded) ===")
    run_tpo_with_iters("small", 1)
    run_stp_with_iters("small", 1)
    GC.gc()
    println("=== Warmup done ===\n")

    results = DataFrame()
    outdir = joinpath(@__DIR__, "results")
    isdir(outdir) || mkpath(outdir)
    csv_path = joinpath(outdir, "comparison.csv")
    md_path = joinpath(outdir, "comparison.md")

    for name in instances
        lsl = ls_limits[name]
        println("\n=== Running $name (LS budget: $(lsl)s) ===")
        flush(stdout)

        tpo = run_tpo_with_iters(name, lsl)
        GC.gc()
        stp = run_stp_with_iters(name, lsl)
        GC.gc()

        print_row_iters(name, tpo, stp)
        flush(stdout)
        row = build_row_iters(name, tpo, stp)
        results = vcat(results, row)
        CSV.write(csv_path, results)
        write_markdown_iters(results, md_path)
    end

    println("\n\nResults written to $csv_path and $md_path")
    println("\n", "="^70)
    show(stdout, results; allrows=true, allcols=true, truncate=0)
    println()
    return results
end

run_comparison()
