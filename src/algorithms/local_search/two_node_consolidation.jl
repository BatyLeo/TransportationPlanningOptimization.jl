"""
$TYPEDSIGNATURES

Bundles whose stored path visits `src` and later `dst`, as `(bundle_idx, lo, hi)` tuples
where `lo` and `hi` are the positions of `src` and `dst` in the path. The nodes need not be
adjacent. Returns bundles in insertion order and skips bundles with empty paths.
"""
function bundles_through_nodes(sol::SolutionState, src::Int, dst::Int)
    out = NTuple{3,Int}[]
    for (i, path) in enumerate(sol.bundle_paths)
        lo = findfirst(==(src), path)
        lo === nothing && continue
        hi = findnext(==(dst), path, lo + 1)
        hi === nothing && continue
        push!(out, (i, lo, hi))
    end
    return out
end

# Rebuild an order of type `O` from merged commodities (recomputes its aggregate).
function _merged_order(
    ::Type{<:Order{IDA,I}}, commodities::Vector{LightCommodity{I}}, t::Int, max_transit::Int
) where {IDA,I}
    return Order{IDA,I}(commodities, t, max_transit)
end

"""
$TYPEDSIGNATURES

Index (in `instance.bundles`) of the bundle of `lifted_idxs` with the longest delivery
window, the donor of [`merge_bundles`](@ref).
"""
function _donor_index(instance::Instance, lifted_idxs::Vector{Int})
    return argmax(
        i -> maximum(o.max_transit_steps for o in instance.bundles[i].orders), lifted_idxs
    )
end

"""
$TYPEDSIGNATURES

Build a virtual bundle merging `lifted_idxs` for the two-node consolidation
Dijkstra.

The donor (bundle with the longest delivery window, see [`_donor_index`](@ref)) provides
origin/destination. Forbidden nodes/arcs are the union over all lifted
bundles. Orders sharing a `time_step` (across lifted bundles) are merged into
one `Order` (keeping the tighter `max_transit_steps`) so their combined load
is priced and capacity-checked together.
"""
function merge_bundles(instance::Instance, lifted_idxs::Vector{Int})
    isempty(lifted_idxs) &&
        throw(ArgumentError("merge_bundles: lifted_idxs cannot be empty"))

    lifted = [instance.bundles[i] for i in lifted_idxs]
    donor = instance.bundles[_donor_index(instance, lifted_idxs)]

    # Orders in different lifted bundles can share a delivery date (the normal
    # case in static instances), pricing one order at a time against the arc
    # would under-count their combined load. Sort by time_step and merge
    # consecutive equal-time_step runs into one Order.
    O = eltype(donor.orders)
    all_lifted_orders = reduce(vcat, [b.orders for b in lifted])
    sort!(all_lifted_orders; by=o -> o.time_step)

    all_orders = O[]
    i = 1
    n = length(all_lifted_orders)
    while i <= n
        j = i
        t = all_lifted_orders[i].time_step
        while j < n && all_lifted_orders[j + 1].time_step == t
            j += 1
        end
        if j == i
            push!(all_orders, all_lifted_orders[i])
        else
            run = @view all_lifted_orders[i:j]
            commodities = reduce(vcat, [o.commodities for o in run])
            max_transit = minimum(o.max_transit_steps for o in run)
            push!(all_orders, _merged_order(O, commodities, t, max_transit))
        end
        i = j + 1
    end

    forbidden_nodes = Set{String}()
    forbidden_arcs = Set{Tuple{String,String}}()
    for b in lifted
        union!(forbidden_nodes, b.forbidden_nodes)
        union!(forbidden_arcs, b.forbidden_arcs)
    end

    return Bundle(;
        orders=all_orders,
        origin_id=donor.origin_id,
        destination_id=donor.destination_id,
        forbidden_nodes=forbidden_nodes,
        forbidden_arcs=forbidden_arcs,
    )
end

"""
$TYPEDSIGNATURES

Replace the positions `lo:hi` of `old_path` with `new_sub_path` and strip the shortcut
nodes of the new sub-path (see `_remove_shortcuts_from_path!`): leading ones in arrival
mode when `lo == 1`, trailing ones in departure mode when `hi == length(old_path)`.
The prefix and the suffix are never shortened.
Returns `(path, new_hi)` where `path` is a fresh `Vector{Int}` and the new sub-path
occupies `lo:new_hi` in it.

Throws `ArgumentError` if `new_sub_path` is empty, if `lo:hi` is not a valid range of
`old_path` or if `new_sub_path` does not start with `old_path[lo]` and end with `old_path[hi]`.

Example: `splice_path([a, src, dst, b], 2, 3, [src, x, dst], ttg)` returns
`([a, src, x, dst, b], 4)`.
"""
function splice_path(
    old_path::Vector{Int}, lo::Int, hi::Int, new_sub_path::Vector{Int}, ttg::TravelTimeGraph
)
    isempty(new_sub_path) &&
        throw(ArgumentError("splice_path: new_sub_path must be non-empty"))
    (1 <= lo <= hi <= length(old_path)) || throw(
        ArgumentError(
            "splice_path: invalid range $lo:$hi for a path of length $(length(old_path))",
        ),
    )
    new_sub_path[1] == old_path[lo] || throw(
        ArgumentError(
            "splice_path: new_sub_path[1] = $(new_sub_path[1]) does not equal old_path[$lo] = $(old_path[lo])",
        ),
    )
    new_sub_path[end] == old_path[hi] || throw(
        ArgumentError(
            "splice_path: new_sub_path[end] = $(new_sub_path[end]) does not equal old_path[$hi] = $(old_path[hi])",
        ),
    )
    path = vcat(old_path[1:(lo - 1)], new_sub_path, old_path[(hi + 1):end])
    _remove_shortcuts_from_path!(path, ttg)
    return path, length(path) - (length(old_path) - hi)
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

Two-node consolidation move on `(src, dst)`: lift the slice from `src` to `dst` of every
bundle whose path visits both nodes (in that order), merge the bundles, reroute the merged
bundle between `src` and `dst` via Dijkstra, splice the new sub-path into each lifted path,
optionally refine, and accept iff the cost strictly improves. Only the slices are removed
and re-added, the prefix and suffix assignments of the lifted bundles are never touched by
the splice (the refinement reinserts whole paths). Returns the cost improvement (`0.0` if
reverted or no bundle visits both nodes).

The cost matrix is only filled on the corridor from `src` to `dst` (see
[`_corridor_arcs`](@ref)). With `refine=false`, a Dijkstra result equal to every old slice
restores the state and returns `0.0` without re-adding anything. The `cost_threshold`
estimate uses the slices only when `refine=false` and the whole paths otherwise.
`rng` drives the refine order.

When the absolute time `deadline` (as `time()`) passes during the move, the move is
rolled back and `0.0` is returned. The deadline is checked after the batched removal, every
few arcs of the merged bundle's cost-matrix sweep, and before the new paths are added.
During the refinement it only stops the remaining reinsertions (the ones already
accepted are kept and the final accept or reject still applies).
"""
function two_node_common_incremental!(
    sol::SolutionState{C},
    instance::Instance,
    src::Int,
    dst::Int;
    mode_selector::AbstractModeSelector=CheapestMode(),
    cost_threshold::Real=0.0,
    refine::Bool=true,
    bundle_adjs::Union{Vector{Dict{Int,Vector{Int}}},Nothing}=nothing,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
    buffer_pool::Union{Vector{<:BinPackingBuffer},Nothing}=nothing,
    snapshot_cache::Union{Dict,Nothing}=nothing,
    deadline::Float64=Inf,
    rng::Random.AbstractRNG=Random.default_rng(),
) where {C}
    lifted = bundles_through_nodes(sol, src, dst)
    isempty(lifted) && return 0.0
    lifted_idxs = [i for (i, _, _) in lifted]

    if cost_threshold > 0
        # Without refinement the move can only save on the slices.
        est_saving = sum(
            bundle_estimated_removal_cost(
                sol,
                instance,
                i,
                refine ? sol.bundle_paths[i] : view(sol.bundle_paths[i], lo:hi),
            ) for (i, lo, hi) in lifted;
            init=0.0,
        )
        est_saving <= cost_threshold && return 0.0
    end

    # The full old paths are kept by reference: nothing mutates them in place.
    old_paths = [sol.bundle_paths[i] for i in lifted_idxs]

    snapshots = Dict{Tuple{Int,Int},_SnapshotUnion{C}}()
    for (i, lo, hi) in lifted
        _snapshot_path_assignments(
            sol, instance, i, view(sol.bundle_paths[i], lo:hi); cache=snapshots, clear=false
        )
    end

    # Track cost deltas from remove/add/refine to avoid calling cost(sol) twice.
    cost_delta = remove_bundle_subpaths!(sol, instance, lifted)
    if time() > deadline
        _restore_multi_bundle_assignments!(sol, lifted_idxs, old_paths, snapshots)
        return 0.0
    end

    ttg = instance.travel_time_graph
    virtual_bundle = merge_bundles(instance, lifted_idxs)
    virtual_arcs = _corridor_arcs(ttg.graph, src, dst)
    empty_counts = empty_pack_counts(instance, virtual_bundle, virtual_arcs)

    in_time = if Threads.nthreads() > 1 && buffer_pool !== nothing
        parallel_update_bundle_cost_matrix!(
            sol,
            instance,
            virtual_bundle,
            virtual_arcs,
            mode_selector,
            buffer_pool;
            empty_counts,
            deadline,
        )
    else
        update_bundle_cost_matrix!(
            sol,
            instance,
            virtual_bundle,
            virtual_arcs,
            mode_selector;
            empty_counts,
            deadline,
        )
    end
    if !in_time
        _restore_multi_bundle_assignments!(sol, lifted_idxs, old_paths, snapshots)
        return 0.0
    end
    spatial = instance.index_cache.ttg_code_to_spatial_code
    parents, _ = bundle_dijkstra(ttg.graph, src, ttg.cost_matrix; dst, workspace)
    new_sub_path = trace_path(parents, src, dst)
    # Splicing can loop even when the sub-path is elementary. In that case search
    # again: only the physical nodes of the untouched prefixes and suffixes are off limits,
    # the interiors of the old slices can be reused.
    splice_all(sub) =
        [splice_path(p, lo, hi, sub, ttg) for (p, (_, lo, hi)) in zip(old_paths, lifted)]
    spliced = Tuple{Vector{Int},Int}[]
    if !isempty(new_sub_path)
        spliced = splice_all(new_sub_path)
        if !all(((p, _),) -> is_elementary_path(p, spatial), spliced)
            avoid = BitSet()
            for (p, (_, lo, hi)) in zip(old_paths, lifted)
                for v in view(p, 1:(lo - 1))
                    push!(avoid, spatial[v])
                end
                for v in view(p, (hi + 1):length(p))
                    push!(avoid, spatial[v])
                end
            end
            delete!(avoid, spatial[src])
            delete!(avoid, spatial[dst])
            new_sub_path = elementary_shortest_path(
                ttg.graph, ttg.cost_matrix, spatial, src, dst; visited=avoid
            )
            isempty(new_sub_path) || (spliced = splice_all(new_sub_path))
        end
    end

    if isempty(new_sub_path) || time() > deadline
        _restore_multi_bundle_assignments!(sol, lifted_idxs, old_paths, snapshots)
        return 0.0
    end

    new_paths = first.(spliced)
    new_his = last.(spliced)
    if !refine && all(
        view(np, lo:nhi) == view(op, lo:hi) for
        (np, op, nhi, (_, lo, hi)) in zip(new_paths, old_paths, new_his, lifted)
    )
        _restore_multi_bundle_assignments!(sol, lifted_idxs, old_paths, snapshots)
        return 0.0
    end

    # Snapshot the edges only the new slices touch, so a rejected move restores them too.
    for ((i, lo, _), np, nhi) in zip(lifted, new_paths, new_his)
        _snapshot_path_assignments(
            sol, instance, i, view(np, lo:nhi); cache=snapshots, clear=false
        )
    end
    for ((i, lo, _), np, nhi) in zip(lifted, new_paths, new_his)
        cost_delta += add_bundle_subpath!(sol, instance, i, np, lo, nhi; mode_selector)
    end

    if refine
        for i in Random.shuffle(rng, lifted_idxs)
            time() > deadline && break
            bundle_adj = bundle_adjs === nothing ? nothing : bundle_adjs[i]
            cost_delta -= _try_reinsert_bundle!(
                sol,
                instance,
                i,
                mode_selector;
                remove_before_routing=false,
                bundle_adj,
                buffer,
                workspace,
                buffer_pool,
                snapshot_cache,
                outer_snapshots=snapshots,
            )
        end
    end

    if cost_delta < -COST_IMPROVEMENT_EPS
        return -cost_delta
    else
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
    sol::SolutionState,
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    time_limit::Real=60.0,
    cost_threshold_relative::Real=5e-5,
    refine::Bool=true,
    rng::Random.AbstractRNG=Random.default_rng(),
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
            deadline=Float64(t_start + time_limit),
            rng,
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
if no bundle visits both nodes or the move was rejected).
"""
function _run_two_node_step!(
    sol::SolutionState,
    instance::Instance,
    valid_pairs::Vector{Tuple{Int,Int}},
    mode_selector::AbstractModeSelector,
    rng::Random.AbstractRNG,
    cost_threshold::Float64,
    refine::Bool;
    bundle_adjs::Union{Vector{Dict{Int,Vector{Int}}},Nothing}=nothing,
    buffer::BinPackingBuffer=BinPackingBuffer(),
    workspace::Union{DijkstraWorkspace,Nothing}=nothing,
    buffer_pool::Union{Vector{<:BinPackingBuffer},Nothing}=nothing,
    snapshot_cache::Union{Dict,Nothing}=nothing,
    deadline::Float64=Inf,
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
        bundle_adjs,
        buffer,
        workspace,
        buffer_pool,
        snapshot_cache,
        deadline,
        rng,
    )
end
