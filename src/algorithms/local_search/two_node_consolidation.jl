"""
$TYPEDSIGNATURES

Indices of bundles whose stored path contains the arc `(src, dst)` as a
consecutive pair. Returns indices in bundle insertion order. Bundles with
empty paths are skipped.
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

Build a virtual bundle merging `lifted_idxs` for the two-node consolidation
Dijkstra. Returns `(virtual_bundle, virtual_bundle_arcs)`.

The donor (bundle with the longest delivery window) provides origin/destination
and the reachable-arc set. Forbidden nodes/arcs are the union over all lifted
bundles.
"""
function merge_bundles(instance::Instance, lifted_idxs::Vector{Int})
    isempty(lifted_idxs) &&
        throw(ArgumentError("merge_bundles: lifted_idxs cannot be empty"))

    lifted = [instance.bundles[i] for i in lifted_idxs]

    donor_local_idx = argmax(
        j -> maximum(o.max_transit_steps for o in lifted[j].orders), eachindex(lifted)
    )
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

Return the valid `(src, dst)` pairs for the two-node consolidation move.

Source candidates are all TTG node codes whose spatial node has
`node_type == :other` (intermediate hubs). Destination candidates are those
plus all codes with `node_type == :destination`. A pair is valid when
`src != dst` and the edge exists in the TTG.

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
    valid_pairs = Tuple{Int,Int}[]
    for s in src_codes, d in dst_codes
        s != d && Graphs.has_edge(g, s, d) && push!(valid_pairs, (s, d))
    end
    return valid_pairs
end

"""
$TYPEDSIGNATURES

Two-node consolidation move on arc `(src, dst)`: lift all bundles traversing
that arc, merge them, reroute the merged bundle via Dijkstra, splice the new
sub-path into each lifted bundle, optionally refine, and accept iff the cost
strictly improves. Returns the cost improvement (`0.0` if reverted or no
bundles traversed the arc).
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
    snapshot_cache::Union{Dict,Nothing}=nothing,
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
            sol,
            instance,
            virtual_bundle,
            virtual_arcs,
            mode_selector,
            buffer_pool;
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
                snapshot_cache,
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

Random-sampling driver for [`two_node_common_incremental!`](@ref): picks
`(src, dst)` pairs at random within the time budget. Returns total cost
improvement.
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
    valid_pairs = compute_candidate_nodes(instance.travel_time_graph)
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

"""
$TYPEDSIGNATURES

One two-node consolidation step: pick a random `(src, dst)` pair from
`valid_pairs` and delegate to `two_node_common_incremental!`. The `refine`
argument forwards to that move (when true, lifted bundles are individually
re-inserted after the splice). Returns the per-step cost improvement (`0.0`
if no bundles traversed the arc or the move was rejected).
"""
function _run_two_node_step!(
    sol::Solution,
    instance::Instance,
    valid_pairs::Vector{Tuple{Int,Int}},
    mode_selector::AbstractModeSelector,
    rng::Random.AbstractRNG,
    cost_threshold::Float64,
    refine::Bool,
    packing::Symbol,
    cost_packing::Symbol;
    bundle_adjs::Union{Vector{Dict{Int,Vector{Int}}},Nothing}=nothing,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
    buffer_pool::Union{Vector{<:BinPackingBuffer},Nothing}=nothing,
    snapshot_cache::Union{Dict,Nothing}=nothing,
)
    isempty(valid_pairs) && return 0.0
    (src, dst) = rand(rng, valid_pairs)
    return two_node_common_incremental!(
        sol,
        instance,
        src,
        dst;
        mode_selector,
        cost_threshold,
        refine,
        packing,
        cost_packing,
        bundle_adjs,
        buffer,
        workspace,
        buffer_pool,
        snapshot_cache,
    )
end
