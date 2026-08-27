using Random

"""
$TYPEDEF

Result returned by [`local_search!`](@ref).

# Fields
$TYPEDFIELDS
"""
struct LocalSearchResult
    "Total cost improvement (accepted moves plus final repack)"
    saved::Float64
    "Cost after local search (`start_cost - saved`)"
    final_cost::Float64
    "Number of iterations performed"
    n_iter::Int
    "Final no-improvement streak length"
    n_no_improv::Int
    "Wall-time samples from start, taken every `sample_every` iterations"
    timestamps::Vector{Float64}
    "Cost snapshots at the same iteration counts as `timestamps`"
    costs::Vector{Float64}
    "Iteration counts at each sample"
    iters_at_sample::Vector{Int}
end

function Base.show(io::IO, r::LocalSearchResult)
    return print(
        io,
        "LocalSearchResult: saved $(round(r.saved; digits=2)) in $(r.n_iter) iterations (final cost: $(round(r.final_cost; digits=2)))",
    )
end

"""
$TYPEDSIGNATURES

Random-neighborhood local search driver mirroring STP's `local_search!`. Each
iteration flips a fair coin to pick one move:

- Bundle reintroduction: a random bundle index is selected, its current path
  is removed, the cost matrix is recomputed against the now-bundle-less
  solution, and a Dijkstra-found new path is accepted iff it strictly improves
  the total cost. Implemented by `_try_reinsert_bundle!`.
- Two-node consolidation: a random `(src, dst)` pair is selected from the set
  of valid `:other -> :other / :destination` arcs in the TTG. Every bundle
  whose current path traverses `(src, dst)` is lifted, a merged virtual bundle
  is rerouted between the two nodes via Dijkstra, and each lifted bundle's
  sub-path is spliced through the new segment. Accepted iff the total cost
  strictly improves. Implemented by `two_node_common_incremental!`.

The loop exits when any of three conditions hits: `time_limit` seconds elapsed,
`max_iter` iterations attempted, or `max_no_improv` consecutive iterations
without improvement (improvement below `1.0`, matching STP's tolerance).

After the loop a single `bin_packing_improvement!` pass is run when
`allow_repack=true`. It is not interleaved per iteration because most
iterations modify zero or very few arcs (a global pass at the end captures the
same opportunities at lower amortized cost).

Per-move pre-filtering: `cost_threshold_relative * start_cost` is passed as the
`cost_threshold` to both move types, so candidates whose estimated removal cost
is below that threshold are skipped without running Dijkstra.

Set `allow_reintro=false` or `allow_consolidate=false` to disable one move type
(useful for ablation studies). Setting both to false skips straight to the
final repack.

`refine_two_node` controls whether lifted bundles are individually re-inserted
after a two-node splice (defaults to `false`, matching STP). Setting it to
`true` can improve per-move quality at the cost of 4-9x slower two-node moves.

The `packing` keyword defaults to `:ffd_union` and controls the commit
operations (remove/add path). The `cost_packing` keyword defaults to
`:frozen` and controls the cost matrix estimation for Dijkstra. Frozen
packing is cheaper (O(n_new) vs O(n_existing + n_new)) and a good estimate.

Returns a [`LocalSearchResult`](@ref) with diagnostic info (cost improvement,
iteration counts, and time-series samples for plotting convergence curves).
"""
function local_search!(
    sol::Solution{C},
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    time_limit::Real=60.0,
    max_iter::Int=500_000,
    max_no_improv::Int=15_000,
    cost_threshold_relative::Real=5e-5,
    allow_reintro::Bool=true,
    allow_consolidate::Bool=true,
    allow_repack::Bool=true,
    refine_two_node::Bool=false,
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
    rng::Random.AbstractRNG=Random.default_rng(),
    sample_every::Int=1000,
) where {C}
    t_start = time()
    start_cost = cost(sol)
    cost_threshold = cost_threshold_relative * start_cost

    ttg = instance.travel_time_graph
    src_codes, dst_codes = compute_candidate_nodes(ttg)
    valid_pairs = Tuple{Int,Int}[]
    for s in src_codes, d in dst_codes
        s != d && Graphs.has_edge(ttg.graph, s, d) && push!(valid_pairs, (s, d))
    end
    can_consolidate = allow_consolidate && !isempty(valid_pairs)
    can_reintro = allow_reintro && !isempty(instance.bundles)

    tot_improv = 0.0
    no_improv = 0
    iter = 0
    timestamps = Float64[0.0]
    costs = Float64[start_cost]
    iters_at_sample = Int[0]

    n_bundles = length(instance.bundles)
    shared_buffer = BinPackingBuffer()
    # Pre-compute per-bundle adjacency lists from bundle_arcs. These are
    # static (independent of the solution) and reused across all lazy
    # Dijkstra calls to avoid per-reinsertion Dict construction.
    bundle_adjs = Vector{Dict{Int,Vector{Int}}}(undef, n_bundles)
    n_ttg_nodes = Graphs.nv(ttg.graph)
    workspace = DijkstraWorkspace(n_ttg_nodes)

    # Thread-local buffer pool for parallel cost matrix computation.
    # One BinPackingBuffer per thread, indexed by threadid().
    buffer_pool = if Threads.nthreads() > 1
        create_buffer_pool()
    else
        nothing
    end

    # Pre-allocated snapshot Dict, reused across iterations via empty!.
    snapshot_cache = Dict{Tuple{Int,Int},_SnapshotUnion{C}}()

    if can_reintro
        ttg = instance.travel_time_graph
        for i in 1:n_bundles
            adj = Dict{Int,Vector{Int}}()
            for (u, v) in ttg.bundle_arcs[i]
                push!(get!(adj, u, Int[]), v)
            end
            bundle_adjs[i] = adj
        end
    end

    if can_reintro || can_consolidate
        while (time() - t_start < time_limit) &&
                  (iter < max_iter) &&
                  (no_improv < max_no_improv)
            take_reintro = if can_reintro && can_consolidate
                rand(rng) < 0.5
            else
                can_reintro
            end

            improved = if take_reintro
                _run_reintro_step!(
                    sol,
                    instance,
                    mode_selector,
                    rng,
                    cost_threshold,
                    packing,
                    cost_packing;
                    buffer=shared_buffer,
                    bundle_adjs,
                    workspace,
                    buffer_pool,
                    snapshot_cache,
                )
            elseif can_consolidate
                _run_two_node_step!(
                    sol,
                    instance,
                    valid_pairs,
                    mode_selector,
                    rng,
                    cost_threshold,
                    refine_two_node,
                    packing,
                    cost_packing;
                    bundle_adjs,
                    buffer=shared_buffer,
                    workspace,
                    buffer_pool,
                    snapshot_cache,
                )
            else
                0.0
            end

            tot_improv += improved
            if improved < 1.0
                no_improv += 1
            else
                no_improv = 0
            end
            iter += 1
            if iter % sample_every == 0
                push!(timestamps, time() - t_start)
                push!(costs, start_cost - tot_improv)
                push!(iters_at_sample, iter)
            end
        end
    end

    if allow_repack
        tot_improv += bin_packing_improvement!(sol, instance)
    end
    push!(timestamps, time() - t_start)
    push!(costs, start_cost - tot_improv)
    push!(iters_at_sample, iter)

    return LocalSearchResult(
        tot_improv,
        start_cost - tot_improv,
        iter,
        no_improv,
        timestamps,
        costs,
        iters_at_sample,
    )
end
