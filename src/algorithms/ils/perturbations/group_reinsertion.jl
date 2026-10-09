"""
$TYPEDEF

Perturbation that removes every bundle of one randomly chosen group and reinserts
them one by one in random order along their cheapest paths (given the current, possibly
slope-scaled, costs). The default groups bundles by destination node, so a whole
destination is rerouted at once. For an origin grouping use `group_by = b -> b.origin_id`.

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
    # Groups are listed in first-seen bundle order, so the pick only depends on `rng`.
    keys_seen = Any[]
    groups = Dict{Any,Vector{Int}}()
    for (i, bundle) in enumerate(instance.bundles)
        isempty(sol.bundle_paths[i]) && continue
        key = p.group_by(bundle)
        if !haskey(groups, key)
            push!(keys_seen, key)
            groups[key] = Int[]
        end
        push!(groups[key], i)
    end
    isempty(keys_seen) && return (0.0, 0)
    bundle_idxs = Random.shuffle(rng, groups[rand(rng, keys_seen)])

    buffer = BinPackingBuffer()
    workspace = DijkstraWorkspace(Graphs.nv(instance.travel_time_graph.graph))
    buffer_pool = Threads.nthreads() > 1 ? create_buffer_pool() : nothing
    result = _reroute_bundles!(
        sol, instance, bundle_idxs; tolerance=p.tolerance
    ) do s, inst, snapshots
        return all(
            _try_insert_bundle!(
                s, inst, b, p.mode_selector; buffer, workspace, buffer_pool, snapshots
            ) for b in bundle_idxs
        )
    end
    if verbose && result[2] > 0
        @info "GroupReinsertPerturbation accepted" n_bundles = length(bundle_idxs) result
    end
    return result
end
