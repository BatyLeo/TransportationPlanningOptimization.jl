# Direct microbench of `_drain_first_matches!` using inputs drawn from a real
# LS run. Compares the adaptive implementation (current) against the pure-Dict
# implementation (rolled back inline) on the same workload.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Printf

const INSTANCE = get(ENV, "INSTANCE", "medium")
const N_SAMPLES = parse(Int, get(ENV, "N_SAMPLES", "10000"))

println("=== Setup TPO instance: $INSTANCE ===")
nodes_file = joinpath(DATA_DIR, "$(INSTANCE)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(INSTANCE)_legs.csv")
com_file = joinpath(DATA_DIR, "$(INSTANCE)_commodities.csv")
(; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

println("=== Filter + init ===")
filtering_sol = TPO.lower_bound_filtering(instance)
sub = TPO.extract_filtered_instance(instance, filtering_sol)
candidates = TPO.mix_greedy_and_lower_bound(sub)
chosen = TPO.choose_best_feasible(
    [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
)

println("=== Capturing real (pool, to_remove) pairs from LS for $(N_SAMPLES) calls ===")
const LC = TPO.LightCommodity{true,Inbound.InboundCommodityInfo}
const SAMPLES = Vector{NTuple{2,Vector{LC}}}()
sizehint!(SAMPLES, N_SAMPLES)

@eval TPO begin
    const CAPTURE_BUF = $SAMPLES
    const CAPTURE_LIMIT = $N_SAMPLES
    function _drain_first_matches!(
        pool::Vector{C}, to_remove::Vector{C}
    ) where {C<:LightCommodity}
        if length(CAPTURE_BUF) < CAPTURE_LIMIT
            push!(CAPTURE_BUF, (copy(pool), copy(to_remove)))
        end
        isempty(to_remove) && return C[]
        if length(to_remove) <= 32
            return _drain_first_matches_linear!(pool, to_remove)
        end
        return _drain_first_matches_dict!(pool, to_remove)
    end
end

GC.gc()
TPO.local_search!(deepcopy(chosen), sub; time_limit=10.0, packing=:frozen)
GC.gc()
println("Captured $(length(SAMPLES)) samples")

# Restore baseline (current) impl
@eval TPO begin
    function _drain_first_matches!(
        pool::Vector{C}, to_remove::Vector{C}
    ) where {C<:LightCommodity}
        isempty(to_remove) && return C[]
        if length(to_remove) <= 32
            return _drain_first_matches_linear!(pool, to_remove)
        end
        return _drain_first_matches_dict!(pool, to_remove)
    end
end

function time_call(impl, samples)
    # Warmup
    for (p, r) in samples[1:min(100, length(samples))]
        impl(copy(p), copy(r))
    end
    GC.gc()
    elapsed = @elapsed for (p, r) in samples
        impl(copy(p), copy(r))
    end
    return elapsed, elapsed / length(samples) * 1e6  # μs/call
end

# Roll back to pure Dict implementation for comparison
function _drain_dict_only!(pool::Vector{C}, to_remove::Vector{C}) where {C<:TPO.LightCommodity}
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
    write_idx = 0
    for read_idx in 1:length(to_remove)
        c = to_remove[read_idx]
        ct = get(counts, c, 0)
        if ct > 0
            counts[c] = ct - 1
            write_idx += 1
            to_remove[write_idx] = c
        end
    end
    resize!(to_remove, write_idx)
    return dropped
end

# Verify equivalence by running both and checking outputs match.
println("\n=== Verify implementations agree on captured samples ===")
mismatches = 0
for (i, (p, r)) in enumerate(SAMPLES[1:min(200, length(SAMPLES))])
    p1, r1 = copy(p), copy(r)
    p2, r2 = copy(p), copy(r)
    d1 = TPO._drain_first_matches!(p1, r1)
    d2 = _drain_dict_only!(p2, r2)
    if length(d1) != length(d2) || length(p1) != length(p2) || length(r1) != length(r2)
        mismatches += 1
        if mismatches <= 3
            @warn "mismatch at sample $i" len_d=(length(d1), length(d2)) len_p=(length(p1), length(p2)) len_r=(length(r1), length(r2))
        end
    end
end
println("Mismatches: $mismatches / $(min(200, length(SAMPLES)))")

println("\n=== Timings on $(length(SAMPLES)) samples (median to_remove ≈ small) ===")
t_adaptive, us_adaptive = time_call(TPO._drain_first_matches!, SAMPLES)
t_dict, us_dict = time_call(_drain_dict_only!, SAMPLES)
@printf("Adaptive (linear<=32 + Dict): %.2f s total, %.2f μs/call\n", t_adaptive, us_adaptive)
@printf("Dict only:                    %.2f s total, %.2f μs/call\n", t_dict, us_dict)
@printf("Speedup: %.2fx\n", t_dict / t_adaptive)

# Stratify by to_remove size
println("\n=== Stratified speedup by to_remove size ===")
buckets = [(1, 5), (5, 10), (10, 20), (20, 32), (33, 100), (100, 10_000)]
for (lo, hi) in buckets
    bucket_samples = filter(((p, r),) -> lo <= length(r) < hi, SAMPLES)
    isempty(bucket_samples) && continue
    t_a, _ = time_call(TPO._drain_first_matches!, bucket_samples)
    t_d, _ = time_call(_drain_dict_only!, bucket_samples)
    @printf("  to_remove ∈ [%3d,%5d): %5d calls, speedup %.2fx\n",
        lo, hi, length(bucket_samples), t_d / t_a)
end
