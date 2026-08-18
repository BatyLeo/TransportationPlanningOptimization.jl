using Random

"""
$TYPEDSIGNATURES

Extended local search following a 4-phase pattern:
1. Identifies bundles routed through arcs where `is_forbidden(instance, u, v)` is true
   (where `u`, `v` are TravelTimeGraph node codes) and removes them
2. Reinserts those bundles via shortest-path with forbidden arcs excluded
3. Runs a two-node consolidation pass on the common network
4. Runs standard [`local_search!`](@ref) (forbidden arcs allowed again)

Returns the total cost improvement.

When `is_forbidden` is `Returns(false)` (the default), no bundle uses a
forbidden arc, so steps 1-3 are a no-op and this is equivalent to plain
`local_search!`.
"""
function large_local_search!(
    sol::Solution,
    instance::Instance;
    is_forbidden=Returns(false),
    mode_selector::AbstractModeSelector=CheapestMode(),
    time_limit::Real=300.0,
    rng::Random.AbstractRNG=Random.default_rng(),
    kwargs...,
)
    start_cost = cost(sol)
    t_start = time()

    # Step 1: Find bundles routed through forbidden arcs
    forbidden_bundles = Int[]
    for (i, path) in enumerate(sol.bundle_paths)
        length(path) < 2 && continue
        for k in 1:(length(path) - 1)
            if is_forbidden(instance, path[k], path[k + 1])
                push!(forbidden_bundles, i)
                break
            end
        end
    end

    if !isempty(forbidden_bundles)
        for b in forbidden_bundles
            remove_bundle_path!(sol, instance, b)
        end

        # Step 2: Reinsert with the forbidden arcs excluded from the cost matrix
        for b in shuffle(rng, forbidden_bundles)
            _reinsert_with_filter!(sol, instance, b, is_forbidden, mode_selector)
        end

        # Step 3: Two-node consolidation pass on the common network
        remaining = time_limit - (time() - t_start)
        if remaining > 0
            loop_two_nodes!(sol, instance, mode_selector; time_limit=remaining * 0.3, rng)
        end
    end

    # Step 4: Standard local search (forbidden arcs allowed again)
    remaining = time_limit - (time() - t_start)
    if remaining > 0
        local_search!(sol, instance, mode_selector; time_limit=remaining, rng, kwargs...)
    end

    return start_cost - cost(sol)
end

"""
$TYPEDSIGNATURES

Reinsert `bundle_idx` (already removed from `sol`) via shortest path on the
TravelTimeGraph, with every arc `(u, v)` for which `is_forbidden(instance, u,
v)` set to `Inf` in the cost matrix. `is_forbidden` is a soft preference, not
a hard routing constraint: if the forbidden arcs disconnect the bundle's
origin from its destination, the bundle falls back to an unrestricted
reinsertion (via [`insert_bundle!`](@ref)) so the solution stays feasible.
"""
function _reinsert_with_filter!(
    sol::Solution,
    instance::Instance,
    bundle_idx::Int,
    is_forbidden,
    mode_selector::AbstractModeSelector,
)
    ttg = instance.travel_time_graph

    # Update cost matrix for this bundle, then blank out the forbidden arcs.
    update_bundle_cost_matrix!(sol, instance, bundle_idx, mode_selector)
    for (u, v) in ttg.bundle_arcs[bundle_idx]
        if is_forbidden(instance, u, v)
            ttg.cost_matrix[u, v] = Inf
        end
    end

    origin = ttg.origin_codes[bundle_idx]
    destination = ttg.destination_codes[bundle_idx]
    parents, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=destination)
    path = trace_path(parents, origin, destination)

    if !isempty(path)
        add_bundle_path!(sol, instance, bundle_idx, path; mode_selector)
    else
        # No feasible path avoiding the forbidden arcs: fall back to an
        # unrestricted reinsertion so every bundle stays routed.
        insert_bundle!(sol, instance, bundle_idx, mode_selector)
    end
    return nothing
end
