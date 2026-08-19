using Random

"""
$TYPEDSIGNATURES

Indices of bundles whose stored path contains the arc `(src, dst)` as a
consecutive pair. Returns indices in bundle insertion order. Bundles with
empty paths are skipped.

This is the lifting step of `two_node_common_incremental!`: it selects which
bundles will be re-routed together through the (src, dst) hub pair.
"""
function bundles_through_arc(sol::Solution, src::Int, dst::Int)
    out = Int[]
    for (i, path) in enumerate(sol.bundle_paths)
        for k in 1:(length(path) - 1)
            if path[k] == src && path[k + 1] == dst
                push!(out, i)
                break
            end
        end
    end
    return out
end

"""
$TYPEDSIGNATURES

Build a virtual bundle representing the union of `lifted_idxs` for the
(src, dst) Dijkstra in `two_node_common_incremental!`. Returns
`(virtual_bundle, virtual_bundle_arcs)`.

- Orders: concatenation of all lifted bundles' orders.
- `origin_id` and `destination_id`: copied from the donor (the lifted bundle
  with the largest `max(o.max_transit_steps for o in bundle.orders)`).
  Using the donor with the longest delivery window gives the most permissive
  arc set for cost-matrix updates.
- `forbidden_nodes` and `forbidden_arcs`: union over lifted bundles, so the
  merged path is guaranteed to satisfy every lifted bundle's individual
  constraints.

The returned `virtual_bundle_arcs` is
`instance.travel_time_graph.bundle_arcs[donor_idx]`, matching the choice in
Renault's `merge_bundles`. This reuses the donor's precomputed reachable-arc
set rather than recomputing one for the virtual bundle (which would require
a BFS that does not amortize).

Throws `ArgumentError` if `lifted_idxs` is empty.
"""
function merge_bundles(instance::Instance, lifted_idxs::Vector{Int})
    isempty(lifted_idxs) &&
        throw(ArgumentError("merge_bundles: lifted_idxs cannot be empty"))

    lifted = [instance.bundles[i] for i in lifted_idxs]

    donor_b = argmax(b -> maximum(o.max_transit_steps for o in b.orders), lifted)
    donor_local_idx = findfirst(==(donor_b), lifted)
    donor_idx = lifted_idxs[donor_local_idx]
    donor = lifted[donor_local_idx]

    all_orders = vcat([b.orders for b in lifted]...)

    forbidden_nodes = Set{String}()
    forbidden_arcs = Set{Tuple{String,String}}()
    for b in lifted
        union!(forbidden_nodes, b.forbidden_nodes)
        union!(forbidden_arcs, b.forbidden_arcs)
    end

    virtual = Bundle(;
        orders=all_orders,
        origin_id=donor.origin_id,
        destination_id=donor.destination_id,
        forbidden_nodes=forbidden_nodes,
        forbidden_arcs=forbidden_arcs,
    )

    return virtual, instance.travel_time_graph.bundle_arcs[donor_idx]
end

"""
$TYPEDSIGNATURES

Replace the `(src, dst)` sub-segment of `old_path` with `new_sub_path`.
Returns a fresh `Vector{Int}`.

Asserts that `new_sub_path` is non-empty, starts with `src`, ends with `dst`,
and that `old_path` contains a consecutive `(src, dst)` pair. Throws
`ArgumentError` otherwise.

Example: `splice_path([a, src, dst, b], src, dst, [src, x, dst])` returns
`[a, src, x, dst, b]`. When `new_sub_path == [src, dst]` (no interior), the
result equals `old_path`.
"""
function splice_path(old_path::Vector{Int}, src::Int, dst::Int, new_sub_path::Vector{Int})
    isempty(new_sub_path) &&
        throw(ArgumentError("splice_path: new_sub_path must be non-empty"))
    new_sub_path[1] == src || throw(
        ArgumentError(
            "splice_path: new_sub_path[1] = $(new_sub_path[1]) does not equal src = $src",
        ),
    )
    new_sub_path[end] == dst || throw(
        ArgumentError(
            "splice_path: new_sub_path[end] = $(new_sub_path[end]) does not equal dst = $dst",
        ),
    )

    for k in 1:(length(old_path) - 1)
        if old_path[k] == src && old_path[k + 1] == dst
            return vcat(old_path[1:k], new_sub_path[2:(end - 1)], old_path[(k + 1):end])
        end
    end
    throw(
        ArgumentError(
            "splice_path: old_path does not contain consecutive ($src, $dst) pair"
        ),
    )
end

"""
$TYPEDSIGNATURES

Return `(src_codes, dst_codes)`, the candidate (src, dst) node pools for the
two-node consolidation move.

- `src_codes`: all TTG node codes whose spatial node has `node_type == :other`
  (intermediate hubs).
- `dst_codes`: `src_codes` plus all codes with `node_type == :destination`.

Mirrors Renault's `compute_src_dst_nodes` (`commonNodes` plus `commonNodes`
union `plant_nodes`) in TPO's typology.
"""
function compute_candidate_nodes(ttg::TravelTimeGraph)
    g = ttg.graph
    src_codes = Int[]
    dst_codes = Int[]
    for label in MetaGraphsNext.labels(g)
        node = g[label]
        code = MetaGraphsNext.code_for(g, label)
        if node.node_type == :other
            push!(src_codes, code)
            push!(dst_codes, code)
        elseif node.node_type == :destination
            push!(dst_codes, code)
        end
    end
    return src_codes, dst_codes
end

"""
$TYPEDSIGNATURES

Two-node common consolidation local-search move on the arc `(src, dst)`.

1. Lift every bundle whose path traverses `(src, dst)` (via
   `bundles_through_arc`).
2. Optionally skip if `cost_threshold > 0` and the sum of
   `bundle_estimated_removal_cost` over lifted bundles is below the threshold.
3. Save each lifted bundle's full path. Snapshot total cost.
4. Remove each lifted bundle entirely.
5. Build a virtual merged bundle via `merge_bundles`.
6. Run Dijkstra on the virtual bundle from `src` to `dst`.
7. For each lifted bundle, splice the new `(src, dst)` sub-segment into its
   old path and re-add the bundle.
8. (Refine step added in Phase 3.7 Task 8.)
9. Accept iff `cost(sol) < cost_before - COST_IMPROVEMENT_EPS`. Otherwise revert all lifted
   bundles to their saved paths.

Returns the cost improvement achieved (`0.0` if reverted or no lifted bundles).
"""
function two_node_common_incremental!(
    sol::Solution,
    instance::Instance,
    src::Int,
    dst::Int;
    mode_selector::AbstractModeSelector=CheapestMode(),
    cost_threshold::Real=0.0,
    refine::Bool=true,
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
    bundle_adjs::Union{Vector{Dict{Int,Vector{Int}}},Nothing}=nothing,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
    buffer_pool::Union{Vector{<:BinPackingBuffer},Nothing}=nothing,
)
    lifted_idxs = bundles_through_arc(sol, src, dst)
    isempty(lifted_idxs) && return 0.0

    if cost_threshold > 0
        est_saving = sum(
            bundle_estimated_removal_cost(sol, instance, i) for i in lifted_idxs; init=0.0
        )
        est_saving <= cost_threshold && return 0.0
    end

    old_paths = [copy(sol.bundle_paths[i]) for i in lifted_idxs]

    snapshots = _snapshot_multi_bundle_assignments(sol, instance, lifted_idxs)

    # Track cost deltas from remove/add/refine to avoid calling cost(sol)
    # twice. _refresh_dirty_assignments! materializes bins but does not
    # change slot.cost, so its delta is zero.
    cost_delta = 0.0
    for i in lifted_idxs
        cost_delta += remove_bundle_path!(sol, instance, i)
    end
    _refresh_dirty_assignments!(sol, instance, keys(snapshots))

    virtual_bundle, virtual_arcs = merge_bundles(instance, lifted_idxs)

    if Threads.nthreads() > 1 && buffer_pool !== nothing
        parallel_update_bundle_cost_matrix!(
            sol, instance, virtual_bundle, virtual_arcs, mode_selector, buffer_pool;
            packing=cost_packing,
        )
    else
        update_bundle_cost_matrix!(
            sol, instance, virtual_bundle, virtual_arcs, mode_selector; packing=cost_packing
        )
    end
    ttg = instance.travel_time_graph
    parents, _ = bundle_dijkstra(ttg.graph, src, ttg.cost_matrix; dst, workspace)
    new_sub_path = trace_path(parents, src, dst)

    if isempty(new_sub_path)
        _restore_multi_bundle_assignments!(sol, lifted_idxs, old_paths, snapshots)
        return 0.0
    end

    for (k, i) in enumerate(lifted_idxs)
        new_path = splice_path(old_paths[k], src, dst, new_sub_path)
        cost_delta += add_bundle_path!(sol, instance, i, new_path; mode_selector, packing)
    end

    if refine
        for i in Random.shuffle(lifted_idxs)
            bundle_adj = bundle_adjs === nothing ? nothing : bundle_adjs[i]
            cost_delta -= _try_reinsert_bundle!(
                sol,
                instance,
                i,
                mode_selector;
                packing,
                cost_packing,
                remove_before_routing=false,
                bundle_adj,
                buffer,
                workspace,
                buffer_pool,
            )
        end
    end

    if cost_delta < -COST_IMPROVEMENT_EPS
        return -cost_delta
    else
        for i in lifted_idxs
            remove_bundle_path!(sol, instance, i)
        end
        _restore_multi_bundle_assignments!(sol, lifted_idxs, old_paths, snapshots)
        return 0.0
    end
end

"""
$TYPEDSIGNATURES

Random-sampling driver for `two_node_common_incremental!`. Picks (src, dst)
candidate pairs at random within the time budget. Returns total cost
improvement.

Candidate pairs are pre-filtered to those where:
- `src` has `node_type == :other` (intermediate hub).
- `dst` has `node_type == :other` or `:destination`.
- The TTG has an edge from `src` to `dst`.

`cost_threshold_relative` scales the absolute `cost_threshold` passed to the
move by `cost(sol)` at the start of the driver, so that bundles with
negligible removal cost are skipped at the same relative magnitude across
instances. Set to `0.0` to disable the filter.

`rng` is a `Random.AbstractRNG` for deterministic testing.
"""
function loop_two_nodes!(
    sol::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    time_limit::Real=60.0,
    cost_threshold_relative::Real=5e-5,
    refine::Bool=true,
    rng::Random.AbstractRNG=Random.default_rng(),
    packing::Symbol=:ffd_union,
    cost_packing::Symbol=:frozen,
)
    src_codes, dst_codes = compute_candidate_nodes(instance.travel_time_graph)
    (isempty(src_codes) || isempty(dst_codes)) && return 0.0

    ttg = instance.travel_time_graph
    valid_pairs = Tuple{Int,Int}[]
    for s in src_codes, d in dst_codes
        s != d && Graphs.has_edge(ttg.graph, s, d) && push!(valid_pairs, (s, d))
    end
    isempty(valid_pairs) && return 0.0

    cost_threshold = cost_threshold_relative * cost(sol)
    saved = 0.0
    t_start = time()
    while time() - t_start < time_limit
        (src, dst) = rand(rng, valid_pairs)
        saved += two_node_common_incremental!(
            sol,
            instance,
            src,
            dst;
            mode_selector,
            cost_threshold,
            refine,
            packing,
            cost_packing,
        )
    end
    return saved
end
