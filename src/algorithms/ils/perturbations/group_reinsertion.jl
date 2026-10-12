"""
$TYPEDEF

Perturbation that removes every bundle of one randomly chosen group and reinserts
them one by one in random order along their cheapest paths for the current costs.
The default groups bundles by destination node, so a whole destination
is rerouted at once. For an origin grouping use `group_by = b -> b.origin_id`.

The new routing is kept if the cost increase is at most `tolerance * cost(sol)`,
otherwise the solution is left unchanged and the perturbation reports no change.

# Fields
$TYPEDFIELDS
"""
@kwdef struct GroupReinsertPerturbation{F,M<:AbstractModeSelector} <: AbstractPerturbation
    "function mapping a [`Bundle`](@ref) to its group key"
    group_by::F = b -> b.destination_id
    "how commodities are spread across the modes of multimodal arcs"
    mode_selector::M = CheapestMode()
    "maximum accepted cost increase, as a fraction of the current cost"
    tolerance::Float64 = 0.015
end

"""
$TYPEDSIGNATURES

Reroute all the routed bundles of one random group of `p.group_by`, see
[`GroupReinsertPerturbation`](@ref).
"""
function perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::GroupReinsertPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    groups = _routed_groups(sol, instance, p.group_by)
    isempty(groups) && return (0.0, 0)
    bundle_idxs = Random.shuffle(rng, rand(rng, groups))

    buffer = BinPackingBuffer()
    workspace = DijkstraWorkspace(Graphs.nv(instance.travel_time_graph.graph))
    # Several threads: parallel cost matrix update, otherwise lazy search (as in
    # `_try_reinsert_bundle!`).
    routing = if Threads.nthreads() > 1
        create_buffer_pool()
    else
        Dict(b => _bundle_adjacency(instance.travel_time_graph, b) for b in bundle_idxs)
    end
    result = _reroute_bundles!(
        sol, instance, bundle_idxs; tolerance=p.tolerance
    ) do s, inst, snapshots
        return all(
            _insert_bundle_snapshotted!(
                s, inst, b, p.mode_selector, snapshots, routing; buffer, workspace
            ) for b in bundle_idxs
        )
    end
    if verbose && result[2] > 0
        @info "GroupReinsertPerturbation accepted" n_bundles = length(bundle_idxs) result
    end
    return result
end

"""
$TYPEDSIGNATURES

Insert bundle `bundle_idx` along its cheapest path and snapshot the edges of that path into
`snapshots` before adding it, as the `reinsert!` step of [`_reroute_bundles!`](@ref) needs.
Returns `false` without modifying `sol` when the bundle has no path.
`routing` selects how the path is found, see [`_group_path!`](@ref).
"""
function _insert_bundle_snapshotted!(
    sol::SolutionState,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector,
    snapshots,
    routing;
    buffer::BinPackingBuffer,
    workspace::DijkstraWorkspace,
)
    ttg = instance.travel_time_graph
    path = _group_path!(
        sol, instance, bundle_idx, mode_selector, routing; buffer, workspace
    )
    isempty(path) && return false
    _remove_shortcuts_from_path!(path, ttg)
    _snapshot_path_assignments(
        sol, instance, bundle_idx, path; cache=snapshots, clear=false
    )
    add_bundle_path!(sol, instance, bundle_idx, path; mode_selector)
    return true
end

"""
$TYPEDSIGNATURES

Cheapest path of bundle `bundle_idx`. With a `routing` that maps bundles to their adjacency
(`Dict`), it comes from the lazy search of [`_lazy_bundle_path!`](@ref). With a buffer pool,
the cost matrix is filled in parallel, then Dijkstra runs.
"""
function _group_path!(
    sol::SolutionState,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector,
    adjacencies::Dict{Int,Dict{Int,Vector{Int}}};
    buffer::BinPackingBuffer,
    workspace::DijkstraWorkspace,
)
    ttg = instance.travel_time_graph
    return _lazy_bundle_path!(
        sol,
        instance,
        bundle_idx,
        ttg.origin_codes[bundle_idx],
        ttg.destination_codes[bundle_idx],
        mode_selector,
        buffer,
        adjacencies[bundle_idx];
        workspace,
    )
end

function _group_path!(
    sol::SolutionState,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector,
    buffer_pool::Vector{<:BinPackingBuffer};
    buffer::BinPackingBuffer,
    workspace::DijkstraWorkspace,
)
    ttg = instance.travel_time_graph
    parallel_update_bundle_cost_matrix!(
        sol, instance, bundle_idx, mode_selector, buffer_pool
    )
    return bundle_shortest_path(
        instance, ttg.origin_codes[bundle_idx], ttg.destination_codes[bundle_idx]; workspace
    )
end
