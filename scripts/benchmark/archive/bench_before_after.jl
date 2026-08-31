# Before/after driver for the assignment-store migration.
#
# Reuses the canonical TPO-vs-STP harness (compare_packages.jl) but on a fixed,
# tractable instance subset with fixed LS budgets, so a "before" and an "after"
# run are directly comparable and each carries its own STP baseline.
#
# Usage:
#   julia --project=scripts scripts/benchmark/bench_before_after.jl before
#   julia --project=scripts scripts/benchmark/bench_before_after.jl after
#
# Writes results/comparison_<tag>.{csv,md}.

# include the harness; its `if abspath(PROGRAM_FILE)==@__FILE__` guard does NOT
# fire here (we are a different PROGRAM_FILE), so compare_all() is not auto-run.
include(joinpath(@__DIR__, "compare_packages.jl"))

const TAG = length(ARGS) >= 1 ? ARGS[1] : "run"

# Same instances and LS budgets for before and after (comparability).
const SUBSET = ["small", "medium", "large", "extra_large"]
const LIMITS = Dict("small" => 8, "medium" => 15, "large" => 20, "extra_large" => 25)

function main()
    # Warmup: run the smallest instance once and discard, to pay JIT before timing.
    @info "Warmup on small..."
    try
        run_tpo("small", 1)
        run_stp("small", 1)
    catch err
        @warn "warmup failed" exception = err
    end
    GC.gc()

    df = DataFrame()
    csv_path = joinpath(OUTPUT_DIR, "comparison_$(TAG).csv")
    md_path = joinpath(OUTPUT_DIR, "comparison_$(TAG).md")
    for name in SUBSET
        lim = LIMITS[name]
        @info "Running $name" ls_limit = lim tag = TAG
        tpo = run_tpo(name, lim)
        GC.gc()
        stp = run_stp(name, lim)
        GC.gc()
        print_row(name, tpo, stp)
        df = vcat(df, build_row(name, tpo, stp))
        CSV.write(csv_path, df)
        write_markdown(df, md_path)
        flush(stdout)
    end
    println("\nDONE [$TAG]. Wrote:\n  $csv_path\n  $md_path")
    return nothing
end

main()
