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

Random-neighborhood local search. Each iteration flips a fair coin between two
moves (bundle reintroduction via [`_try_reinsert_bundle!`](@ref) and two-node
consolidation via [`two_node_common_incremental!`](@ref)), accepting strictly
improving moves only.

Stops when `time_limit`, `max_iter`, or `max_no_improv` consecutive non-improving
iterations is reached. A final [`bin_packing_improvement!`](@ref) pass runs when
`allow_repack=true`.

Set `allow_reintro=false` or `allow_consolidate=false` to disable one move type.

Returns a [`LocalSearchResult`](@ref) with cost improvement, iteration counts,
and time-series samples for convergence analysis.
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
    valid_pairs = compute_candidate_nodes(ttg)
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
    n_ttg_nodes = Graphs.nv(ttg.graph)
    workspace = DijkstraWorkspace(n_ttg_nodes)

    buffer_pool = if Threads.nthreads() > 1
        create_buffer_pool()
    else
        nothing
    end

    snapshot_cache = Dict{Tuple{Int,Int},_SnapshotUnion{C}}()

    # Adjacency lists are needed for lazy Dijkstra (reintro) and for the
    # refine step inside two-node consolidation.
    needs_adjs = can_reintro || (can_consolidate && refine_two_node)
    bundle_adjs = needs_adjs ? _compute_bundle_adjacencies(ttg, n_bundles) : nothing

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
