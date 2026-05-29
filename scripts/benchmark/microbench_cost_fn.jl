# Micro-benchmark TPO's per-arc cost computation and quantify the impact of
# each candidate optimization.
#
# Reference: the per-arc cost function called inside `update_bundle_cost_matrix!`
# is `compute_ttg_edge_incremental_cost` (`src/algorithms/cost_matrix_update.jl:497`).
# We compare its current shape against three patched variants:
#   A: drop the separate node-cost call (lines 545-560 of cost_matrix_update.jl)
#   B: drop the per-call `label_for` lookups (lines 508-509)
#   C: drop the materialization of MultiAssignment existing commodities
#      (the `collect(commodities_of(...))` branch)
# Each variant is wired in via the `cost_fn` kwarg of `update_bundle_cost_matrix!`,
# so the only thing that differs between runs is the per-arc function called.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Printf
using SparseArrays

const INSTANCE = get(ENV, "INSTANCE", "medium")

println("=== Loading $INSTANCE ===")
nodes_file = joinpath(DATA_DIR, "$(INSTANCE)_nodes.csv")
legs_file = joinpath(DATA_DIR, "$(INSTANCE)_legs.csv")
com_file = joinpath(DATA_DIR, "$(INSTANCE)_commodities.csv")
(; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

println("=== Build init solution (so existing_assignment paths are non-trivial) ===")
filtering_sol = TPO.lower_bound_filtering(instance)
sub = TPO.extract_filtered_instance(instance, filtering_sol)
candidates = TPO.mix_greedy_and_lower_bound(sub)
chosen = TPO.choose_best_feasible(
    [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
)

println("=== Pick representative bundles (median bundle_arcs size) ===")
ttg = sub.travel_time_graph
arcs_per_bundle = [length(ttg.bundle_arcs[i]) for i in eachindex(sub.bundles)]
sorted_idxs = sortperm(arcs_per_bundle)
median_idx = sorted_idxs[length(sorted_idxs) ÷ 2]
p10_idx = sorted_idxs[length(sorted_idxs) ÷ 10]
p90_idx = sorted_idxs[9 * length(sorted_idxs) ÷ 10]
test_bundles = [p10_idx, median_idx, p90_idx]
println("Bundle arcs distribution (min/p10/median/p90/max): ",
        minimum(arcs_per_bundle), "/", arcs_per_bundle[p10_idx], "/",
        arcs_per_bundle[median_idx], "/", arcs_per_bundle[p90_idx], "/",
        maximum(arcs_per_bundle))

# -------------------------------------------------------------------------
# Variants: copies of compute_ttg_edge_incremental_cost with specific
# pieces removed.
# -------------------------------------------------------------------------

const ME = TPO.MetaGraphsNext

"""
Variant A — drop the node-cost block. Skips the second incremental_cost!
call per order. Returns a cost that is *not* equal to baseline (it omits the
NodeVolumeCost contribution), but that's fine: we are timing per-arc work,
not validating cost values.
"""
function cost_fn_no_node(
    current_solution::TPO.Solution{C},
    instance::TPO.Instance,
    bundle::TPO.Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::TPO.AbstractModeSelector;
    buffer::TPO.BinPackingBuffer,
    packing::Symbol=:frozen,
) where {C}
    u_ttg_label = ME.label_for(instance.travel_time_graph.graph, u_ttg_code)
    v_ttg_label = ME.label_for(instance.travel_time_graph.graph, v_ttg_code)
    u_ttg_label[1] == v_ttg_label[1] && return 0.0
    cache = instance.index_cache
    total = 0.0
    for order in bundle.orders
        u_tsg = TPO.project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = TPO.project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        arc = get(cache.arc_of, (su, sv), nothing)
        arc === nothing && return Inf
        edge = (u_tsg, v_tsg)
        existing_assignment = get(current_solution.assignments, edge, nothing)
        total += TPO._edge_incremental_cost(
            buffer, arc, existing_assignment, order.commodities, mode_selector;
            packing=packing,
        )
        # Node-cost block intentionally omitted.
    end
    return total
end

"""
Variant B — drop the per-call `label_for` lookups by accepting precomputed
spatial-equality info. Since label_for is called once per call (not per
order), the impact is small per call but multiplied by the number of arcs in
the bundle. We simulate the savings by hardcoding `false` for the
shortcut-arc early exit; this is correct in this microbenchmark because
`bundle_arcs[bundle_idx]` already excludes shortcuts (per their construction).
"""
function cost_fn_no_label_for(
    current_solution::TPO.Solution{C},
    instance::TPO.Instance,
    bundle::TPO.Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::TPO.AbstractModeSelector;
    buffer::TPO.BinPackingBuffer,
    packing::Symbol=:frozen,
) where {C}
    # Skip the two label_for calls. Bundle arcs are non-shortcut by construction,
    # so the early-exit they gate doesn't apply here.
    cache = instance.index_cache
    total = 0.0
    for order in bundle.orders
        u_tsg = TPO.project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = TPO.project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        arc = get(cache.arc_of, (su, sv), nothing)
        arc === nothing && return Inf
        edge = (u_tsg, v_tsg)
        existing_assignment = get(current_solution.assignments, edge, nothing)
        total += TPO._edge_incremental_cost(
            buffer, arc, existing_assignment, order.commodities, mode_selector;
            packing=packing,
        )
        node_cost = cache.node_cost_of[sv]
        existing_at_dst_node = if existing_assignment === nothing
            C[]
        elseif existing_assignment isa TPO.SingleAssignment
            existing_assignment.commodities
        else
            collect(TPO.commodities_of(existing_assignment))
        end
        total += TPO.incremental_cost!(
            buffer, node_cost, existing_at_dst_node, order.commodities
        )
    end
    return total
end

"""
Variant C — drop both label_for AND node cost. Combined effect of A+B.
"""
function cost_fn_no_node_no_label(
    current_solution::TPO.Solution{C},
    instance::TPO.Instance,
    bundle::TPO.Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::TPO.AbstractModeSelector;
    buffer::TPO.BinPackingBuffer,
    packing::Symbol=:frozen,
) where {C}
    cache = instance.index_cache
    total = 0.0
    for order in bundle.orders
        u_tsg = TPO.project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = TPO.project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        arc = get(cache.arc_of, (su, sv), nothing)
        arc === nothing && return Inf
        edge = (u_tsg, v_tsg)
        existing_assignment = get(current_solution.assignments, edge, nothing)
        total += TPO._edge_incremental_cost(
            buffer, arc, existing_assignment, order.commodities, mode_selector;
            packing=packing,
        )
    end
    return total
end

"""
Variant D — skip `_edge_incremental_cost` entirely. Just do the bookkeeping
(projection, cache lookups, dict gets) and a trivial constant cost. Measures
how much of per-call time is bookkeeping vs. cost-fn body.
"""
function cost_fn_only_bookkeeping(
    current_solution::TPO.Solution{C},
    instance::TPO.Instance,
    bundle::TPO.Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::TPO.AbstractModeSelector;
    buffer::TPO.BinPackingBuffer,
    packing::Symbol=:frozen,
) where {C}
    u_ttg_label = ME.label_for(instance.travel_time_graph.graph, u_ttg_code)
    v_ttg_label = ME.label_for(instance.travel_time_graph.graph, v_ttg_code)
    u_ttg_label[1] == v_ttg_label[1] && return 0.0
    cache = instance.index_cache
    total = 0.0
    for order in bundle.orders
        u_tsg = TPO.project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = TPO.project_to_time_space_graph(v_ttg_code, order, instance)
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        arc = get(cache.arc_of, (su, sv), nothing)
        arc === nothing && return Inf
        edge = (u_tsg, v_tsg)
        existing_assignment = get(current_solution.assignments, edge, nothing)
        total += 1.0  # placeholder, no bin packing
    end
    return total
end

"""
Variant E — fully empty body (returns 0 immediately). Measures the per-arc
loop overhead in `update_bundle_cost_matrix!` itself (sparsity-pattern write,
forbidden-set check, dispatch).
"""
function cost_fn_noop(
    current_solution::TPO.Solution{C},
    instance::TPO.Instance,
    bundle::TPO.Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::TPO.AbstractModeSelector;
    buffer::TPO.BinPackingBuffer,
    packing::Symbol=:frozen,
) where {C}
    return 0.0
end

# -------------------------------------------------------------------------
# Timing harness
# -------------------------------------------------------------------------

const N_REPEATS = parse(Int, get(ENV, "N_REPEATS", "200"))

"""
Run `update_bundle_cost_matrix!` `n_reps` times for the given bundle and
cost_fn. Returns (mean time per call in ms, total wall time).
"""
function time_one(cost_fn, sub, bundle_idx, n_reps=N_REPEATS; packing::Symbol=:ffd_union)
    ttg = sub.travel_time_graph
    bundle = sub.bundles[bundle_idx]
    bundle_arcs = ttg.bundle_arcs[bundle_idx]
    buffer = TPO.BinPackingBuffer()
    # Warmup (JIT)
    TPO.update_bundle_cost_matrix!(
        chosen, sub, bundle, bundle_arcs; cost_fn, buffer, packing,
    )
    # Timed runs
    elapsed = @elapsed for _ in 1:n_reps
        TPO.update_bundle_cost_matrix!(
            chosen, sub, bundle, bundle_arcs; cost_fn, buffer, packing,
        )
    end
    return (elapsed / n_reps * 1000, elapsed)
end

variants = [
    ("baseline :ffd_union (LS default)", TPO.compute_ttg_edge_incremental_cost),
    ("A: no node cost",                cost_fn_no_node),
    ("B: no label_for",                cost_fn_no_label_for),
    ("C: A + B combined",              cost_fn_no_node_no_label),
    ("D: bookkeeping only (no bin pack)", cost_fn_only_bookkeeping),
    ("E: empty (just outer loop)",     cost_fn_noop),
]

println("\n=== Per-arc cost-fn timings (mean per `update_bundle_cost_matrix!` call) ===\n")
@printf("%-30s %12s %12s %12s\n", "Bundle", "p10 arcs", "median arcs", "p90 arcs")
println()
println("Bundle.arcs counts:")
@printf("  p10:    %4d arcs\n", arcs_per_bundle[p10_idx])
@printf("  median: %4d arcs\n", arcs_per_bundle[median_idx])
@printf("  p90:    %4d arcs\n", arcs_per_bundle[p90_idx])

results = Dict{String,Vector{Float64}}()
for (label, fn) in variants
    println("\n--- Variant: $label ---")
    times = Float64[]
    for (i, b_idx) in enumerate(test_bundles)
        nrepeats = N_REPEATS
        (per_call_ms, total_s) = time_one(fn, sub, b_idx, nrepeats)
        push!(times, per_call_ms)
        bname = i == 1 ? "p10" : i == 2 ? "median" : "p90"
        @printf("  %-8s bundle (%4d arcs): %8.3f ms/call  (%.2fs over %d reps)\n",
            bname, arcs_per_bundle[b_idx], per_call_ms, total_s, nrepeats)
    end
    results[label] = times
end

# Also measure baseline with packing=:frozen — this is the STP-like commit model
# that avoids re-packing the existing commodities on every order.
println("\n--- Variant: baseline (packing=:frozen instead of :ffd_union) ---")
frozen_times = Float64[]
for (i, b_idx) in enumerate(test_bundles)
    (per_call_ms, total_s) = time_one(
        TPO.compute_ttg_edge_incremental_cost, sub, b_idx, N_REPEATS; packing=:frozen,
    )
    push!(frozen_times, per_call_ms)
    bname = i == 1 ? "p10" : i == 2 ? "median" : "p90"
    @printf("  %-8s bundle (%4d arcs): %8.3f ms/call  (%.2fs over %d reps)\n",
        bname, arcs_per_bundle[b_idx], per_call_ms, total_s, N_REPEATS)
end
results["baseline (packing=:frozen)"] = frozen_times
push!(variants, ("baseline (packing=:frozen)", TPO.compute_ttg_edge_incremental_cost))

println("\n=== Speedup vs baseline (per-call time ratio: variant/baseline) ===")
println()
@printf("%-40s %12s %12s %12s\n", "Variant", "p10", "median", "p90")
baseline = results["baseline :ffd_union (LS default)"]
for (label, _) in variants
    ratio = results[label] ./ baseline
    @printf("%-40s %11.3f %11.3f %11.3f\n",
        label, ratio[1], ratio[2], ratio[3])
end

println("\n=== Throughput impact ===")
println("If LS spends ~70% of time in update_bundle_cost_matrix! (per profile),")
println("and a variant cuts that by X%, then LS iter/s gain ≈ 1/(1 - 0.7X)")
for (label, _) in variants
    median_ratio = results[label][2] / baseline[2]
    cut_pct = (1 - median_ratio) * 100
    iter_s_factor = 1 / (1 - 0.7 * (1 - median_ratio))
    @printf("  %-40s cuts cost-fn by %5.1f%%, expected LS iter/s ~ %.2fx baseline\n",
        label, cut_pct, iter_s_factor)
end
