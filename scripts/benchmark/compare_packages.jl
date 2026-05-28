# Full-pipeline performance comparison between TransportationPlanningOptimization
# (TPO) and ShipperTransportationPlanning (STP) on the inbound benchmark
# instances.
#
# This is a standalone script, NOT a test. It runs each package's heuristic
# pipeline (lower-bound filtering, then the mixed initial solution, then a
# time-limited local search) on every instance and writes a side-by-side
# comparison of cost and wall-clock time.
#
# ILS is intentionally excluded: TPO's Phase 6 (LNS / ILS) is not built yet.
#
# Run with:
#   julia --project=scripts scripts/benchmark/compare_packages.jl
#
# Results are written incrementally (one row per instance, as each finishes) to
#   scripts/benchmark/results/comparison.csv   (machine-readable)
#   scripts/benchmark/results/comparison.md    (human-readable)
# so a crash on a large instance does not lose the earlier rows.

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

# Instances to compare, smallest first. Comment out the large ones for a quick
# run. `world5` can take a long time just to build the graphs.
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

# Local-search wall-clock budget (seconds) per instance. Both packages get the
# same budget on the same instance. Override here for a quick run (e.g. set all
# to 10). `default_ls_limit` is used for any instance not listed.
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
default_ls_limit(name::String) = get(LS_TIME_LIMITS, name, 60)

# Skip instances that already have a row in the CSV (makes the script
# resumable across runs).
const SKIP_EXISTING = true

# ---------------------------------------------------------------------------
# TPO pipeline
# ---------------------------------------------------------------------------

"""
Run TPO's heuristic pipeline on instance `name` and return a NamedTuple of
costs, times, and feasibility flags. Costs are full-instance costs (filtered
bundles merged back) via `cost_with_nodes`.
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

    ls_time = @elapsed TPO.local_search!(chosen, sub; time_limit=ls_limit)
    ls_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    ls_cost = TPO.cost_with_nodes(ls_full, instance)
    ls_feasible = TPO.is_feasible(ls_full, instance)

    return (;
        n_bundles=length(instance.bundles),
        build_time,
        filter_time,
        init_cost,
        init_time,
        init_feasible,
        ls_cost,
        ls_time,
        ls_feasible,
    )
end

# ---------------------------------------------------------------------------
# STP pipeline
# ---------------------------------------------------------------------------

"""
Run STP's heuristic pipeline on instance `name`, mirroring `julia_main_test`'s
filter / mix / choose-best / local-search prefix. Returns the same NamedTuple
shape as `run_tpo`. Costs are full-instance costs (merged back) via
`compute_cost`.

Note the flipped `merge_solutions` argument order versus TPO: STP takes the
sub solution first, the full (filtering) solution second.
"""
function run_stp(name::String, ls_limit::Real)
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

    ls_time = @elapsed STP.local_search!(chosen, sub; timeLimit=ls_limit)
    ls_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    ls_cost = STP.compute_cost(instance, ls_full)
    ls_feasible = STP.is_feasible(instance, ls_full)

    return (;
        n_bundles=length(instance.bundles),
        build_time,
        filter_time,
        init_cost,
        init_time,
        init_feasible,
        ls_cost,
        ls_time,
        ls_feasible,
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

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

const CSV_COLUMNS = [
    :instance,
    :n_bundles,
    :tpo_build_s,
    :stp_build_s,
    :tpo_filter_s,
    :stp_filter_s,
    :tpo_init_cost,
    :stp_init_cost,
    :init_cost_ratio,
    :tpo_init_s,
    :stp_init_s,
    :tpo_ls_cost,
    :stp_ls_cost,
    :ls_cost_ratio,
    :tpo_ls_s,
    :stp_ls_s,
    :tpo_init_feasible,
    :stp_init_feasible,
    :tpo_ls_feasible,
    :stp_ls_feasible,
]

"Build a single-row DataFrame from one instance's TPO and STP results."
function build_row(name::String, tpo, stp)
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
        tpo_init_feasible=[tpo.init_feasible],
        stp_init_feasible=[stp.init_feasible],
        tpo_ls_feasible=[tpo.ls_feasible],
        stp_ls_feasible=[stp.ls_feasible],
    )
end

"Print a concise console summary of one instance's result."
function print_row(name::String, tpo, stp)
    @printf("\n%-12s  (%d bundles)\n", name, tpo.n_bundles)
    @printf("  %-10s %14s %14s %8s\n", "stage", "TPO", "STP", "TPO/STP")
    @printf(
        "  %-10s %14.1f %14.1f %8.4f\n",
        "init cost",
        tpo.init_cost,
        stp.init_cost,
        tpo.init_cost / stp.init_cost,
    )
    @printf(
        "  %-10s %14.1f %14.1f %8.4f\n",
        "LS cost",
        tpo.ls_cost,
        stp.ls_cost,
        tpo.ls_cost / stp.ls_cost,
    )
    @printf("  %-10s %14.2f %14.2f\n", "build s", tpo.build_time, stp.build_time)
    @printf("  %-10s %14.2f %14.2f\n", "LS s", tpo.ls_time, stp.ls_time)
    if !(tpo.ls_feasible && stp.ls_feasible)
        @printf(
            "  WARNING infeasible: tpo_ls=%s stp_ls=%s\n", tpo.ls_feasible, stp.ls_feasible,
        )
    end
    return nothing
end

"Render the full results DataFrame as a markdown table."
function write_markdown(df::DataFrame, path::String)
    open(path, "w") do io
        println(io, "# TPO vs STP full-pipeline comparison")
        println(io)
        println(io, "Generated: ", Dates.now())
        println(io)
        println(io, "Ratios are TPO / STP (< 1 means TPO is cheaper / faster).")
        println(io)
        # Header.
        cols = names(df)
        println(io, "| " * join(cols, " | ") * " |")
        println(io, "| " * join(fill("---", length(cols)), " | ") * " |")
        for row in eachrow(df)
            println(io, "| " * join((string(row[c]) for c in cols), " | ") * " |")
        end
        # Summary: geometric mean of the cost ratios.
        println(io)
        if nrow(df) > 0
            init_geomean = exp(sum(log, df.init_cost_ratio) / nrow(df))
            ls_geomean = exp(sum(log, df.ls_cost_ratio) / nrow(df))
            println(io, "## Summary")
            println(io)
            @printf(io, "- Geometric-mean init-cost ratio (TPO/STP): %.4f\n", init_geomean,)
            @printf(io, "- Geometric-mean LS-cost ratio (TPO/STP): %.4f\n", ls_geomean)
        end
    end
    return nothing
end

"""
Run the comparison over all configured instances. Writes the CSV and markdown
after each instance so partial progress survives a crash.

Pass `ls_limit_override` to use the same local-search budget (seconds) for
every instance instead of the size-scaled `LS_TIME_LIMITS`. Useful for a quick
pass across all instances before committing to a long full-budget run.
"""
function compare_all(; ls_limit_override::Union{Nothing,Real}=nothing)
    isdir(OUTPUT_DIR) || mkpath(OUTPUT_DIR)
    csv_path = joinpath(OUTPUT_DIR, "comparison.csv")
    md_path = joinpath(OUTPUT_DIR, "comparison.md")

    df = if SKIP_EXISTING && isfile(csv_path)
        DataFrame(CSV.File(csv_path))
    else
        DataFrame()
    end
    done = nrow(df) > 0 ? Set(string.(df.instance)) : Set{String}()

    # JIT warmup on the smallest instance (timings on it are discarded).
    if !isempty(INSTANCES)
        @info "Warming up JIT on $(first(INSTANCES)) (timings discarded)"
        try
            run_tpo(first(INSTANCES), 1)
            run_stp(first(INSTANCES), 1)
        catch err
            @warn "Warmup failed (continuing)" exception = err
        end
    end

    for name in INSTANCES
        if name in done
            @info "Skipping $name (already in CSV)"
            continue
        end
        ls_limit =
            ls_limit_override === nothing ? default_ls_limit(name) : ls_limit_override
        @info "Running $name" ls_limit
        local tpo, stp
        try
            tpo = run_tpo(name, ls_limit)
            stp = run_stp(name, ls_limit)
        catch err
            @error "Instance $name failed, skipping" exception = (err, catch_backtrace())
            continue
        end
        print_row(name, tpo, stp)
        df = vcat(df, build_row(name, tpo, stp))
        CSV.write(csv_path, df)
        write_markdown(df, md_path)
        @info "Wrote results through $name" csv_path md_path
    end

    println("\n", "="^60)
    println("Comparison complete. Results in:")
    println("  ", csv_path)
    println("  ", md_path)
    return df
end

# Run when executed as a script (not when included in a REPL for inspection).
if abspath(PROGRAM_FILE) == @__FILE__
    compare_all()
end
