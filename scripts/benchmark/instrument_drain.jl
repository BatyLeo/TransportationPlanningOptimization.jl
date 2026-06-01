# Instrument `_drain_first_matches!` to record the size distribution of its
# arguments during a 10s LS run. We need this to decide whether replacing
# the Dict{LightCommodity,Int} with a linear scan is a clear win across the
# call distribution.
include(joinpath(@__DIR__, "compare_packages.jl"))

const INSTANCE = get(ENV, "INSTANCE", "medium")
const LS_BUDGET = parse(Float64, get(ENV, "LS_BUDGET", "10"))
const PACKING = Symbol(get(ENV, "PACKING", "frozen"))

println("=== Setting up TPO instance: $INSTANCE (packing=$PACKING) ===")
nodes_file = joinpath(DATA_DIR, "$(INSTANCE)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(INSTANCE)_legs.csv")
com_file = joinpath(DATA_DIR, "$(INSTANCE)_commodities.csv")
(; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

println("=== Filter + init solution ===")
filtering_sol = TPO.lower_bound_filtering(instance)
sub = TPO.extract_filtered_instance(instance, filtering_sol)
candidates = TPO.mix_greedy_and_lower_bound(sub)
chosen = TPO.choose_best_feasible(
    [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
)

println("=== Warmup LS (1s) ===")
TPO.local_search!(deepcopy(chosen), sub; time_limit=1.0, packing=PACKING)
GC.gc()

println("=== Instrumenting _drain_first_matches! ===")

# Records of (length(pool), length(to_remove)) per call.
const DRAIN_RECORDS = Vector{Tuple{Int,Int}}()
sizehint!(DRAIN_RECORDS, 5_000_000)

# Redefine inside TPO module. This patches the function so all internal
# callers pick up the new definition via Julia's late binding.
@eval TPO begin
    function _drain_first_matches!(
        pool::Vector{C}, to_remove::Vector{C}
    ) where {C<:LightCommodity}
        # ↓ instrumentation
        push!($DRAIN_RECORDS, (length(pool), length(to_remove)))
        # ↑ instrumentation
        isempty(to_remove) && return C[]
        counts = Dict{C,Int}()
        for c in to_remove
            counts[c] = get(counts, c, 0) + 1
        end
        n_pool = length(pool)
        write_idx = 0
        dropped = C[]
        for read_idx in 1:n_pool
            c = pool[read_idx]
            ct = get(counts, c, 0)
            if ct > 0
                counts[c] = ct - 1
                push!(dropped, c)
            else
                write_idx += 1
                pool[write_idx] = c
            end
        end
        resize!(pool, write_idx)
        # Build the remaining: items in to_remove whose count wasn't fully drained
        unmatched = C[]
        for (c, ct) in counts
            for _ in 1:ct
                push!(unmatched, c)
            end
        end
        resize!(to_remove, length(unmatched))
        copyto!(to_remove, unmatched)
        return dropped
    end
end

println("=== Running LS for $(LS_BUDGET)s with instrumentation ===")
GC.gc()
chosen_run = deepcopy(chosen)
t = @elapsed result = TPO.local_search!(
    chosen_run, sub; time_limit=LS_BUDGET, packing=PACKING
)
println("LS done: $(result.n_iter) iters in $(round(t; digits=2))s")
println("_drain_first_matches! called $(length(DRAIN_RECORDS)) times")
println("Calls per iter: $(round(length(DRAIN_RECORDS) / max(result.n_iter, 1); digits=1))")

using Printf, Statistics
pool_sizes = [r[1] for r in DRAIN_RECORDS]
remove_sizes = [r[2] for r in DRAIN_RECORDS]

function show_stats(name, vals)
    println("\n=== $name distribution ===")
    @printf("  min:    %d\n", minimum(vals))
    @printf("  p10:    %d\n", quantile(vals, 0.10))
    @printf("  p25:    %d\n", quantile(vals, 0.25))
    @printf("  median: %d\n", median(vals))
    @printf("  mean:   %.1f\n", mean(vals))
    @printf("  p75:    %d\n", quantile(vals, 0.75))
    @printf("  p90:    %d\n", quantile(vals, 0.90))
    @printf("  p95:    %d\n", quantile(vals, 0.95))
    @printf("  p99:    %d\n", quantile(vals, 0.99))
    @printf("  max:    %d\n", maximum(vals))
end

show_stats("pool size (assignment commodities)", pool_sizes)
show_stats("to_remove size (order commodities)", remove_sizes)

println("\n=== Bucketed histogram of to_remove size ===")
buckets = [0, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 10_000]
for i in 1:(length(buckets) - 1)
    lo, hi = buckets[i], buckets[i + 1]
    n = count(s -> lo <= s < hi, remove_sizes)
    pct = 100 * n / length(remove_sizes)
    @printf("  [%4d, %5d): %8d calls (%5.1f%%)\n", lo, hi, n, pct)
end

println("\n=== Bucketed histogram of pool size ===")
for i in 1:(length(buckets) - 1)
    lo, hi = buckets[i], buckets[i + 1]
    n = count(s -> lo <= s < hi, pool_sizes)
    pct = 100 * n / length(pool_sizes)
    @printf("  [%4d, %5d): %8d calls (%5.1f%%)\n", lo, hi, n, pct)
end

println("\n=== Cost model: time per call (in hypothetical units) ===")
# Dict cost model: K_dict_alloc + K_hash * (|to_remove| + |pool|)
# Linear-scan cost model: K_linear * |to_remove| * |pool|
# We just report which calls would prefer which strategy under a simple model.
# Cross-over (linear cheaper): K_linear * |to_remove| * |pool| < K_hash * (|to_remove| + |pool|)
# Simplify to: |to_remove| * |pool| / (|to_remove| + |pool|) < K_hash / K_linear ≈ 8
# So linear is faster when min(|to_remove|, |pool|) is below a small threshold.
threshold = 16  # heuristic: when min < 16, linear wins
linear_better = count(((p, r),) -> min(p, r) < threshold, DRAIN_RECORDS)
@printf(
    "Calls where min(pool, to_remove) < %d (linear scan would likely win): %d (%.1f%%)\n",
    threshold,
    linear_better,
    100 * linear_better / length(DRAIN_RECORDS)
)
