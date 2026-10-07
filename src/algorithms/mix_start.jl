"""
$TYPEDSIGNATURES

Build three solutions in a single sweep over bundles: pure greedy, pure lower bound, and a mixed
solution whose Dijkstra cost matrix blends the two strategies with weights
that shift toward greedy as more bundles are placed.

Returns `(; mixed, greedy, lower_bound)`. All three solutions are independent
`SolutionState` objects, suitable for `cost`, `is_feasible`, and downstream local
search.

```
mix_cost = (i / B) * greedy_cost + (1 - i / B) * lb_cost
```
where `i` is the 1-indexed iteration and `B` is the total bundle count. This
is a convex blend: the first bundles are placed almost purely on lower-bound
costs, and the greedy share grows linearly to dominate the last bundles.

`start` seeds all three candidates via `deepcopy` (default `SolutionState(instance)`,
i.e. empty), so a caller can pre-load a capacity and cost floor (see
[`preload_filtered_bundles`](@ref)) that every candidate then builds on top of.
Set `show_progress=false` to hide the progress bar.
"""
function mix_greedy_and_lower_bound(
    instance::Instance;
    mode_selector::AbstractModeSelector=CheapestMode(),
    start::SolutionState=SolutionState(instance),
    show_progress::Bool=true,
)
    ttg = instance.travel_time_graph
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    B = length(instance.bundles)

    greedy_sol = deepcopy(start)
    lb_sol = deepcopy(start)
    mixed_sol = deepcopy(start)

    # One bin-packing scratch buffer reused across every bundle and arc.
    buffer = BinPackingBuffer()

    @showprogress enabled = show_progress for (i, bundle_idx) in enumerate(sorted_indices)
        bundle_arcs = ttg.bundle_arcs[bundle_idx]
        origin = ttg.origin_codes[bundle_idx]
        destination = ttg.destination_codes[bundle_idx]
        bundle = instance.bundles[bundle_idx]

        # Greedy strategy: incremental costs against greedy_sol.
        update_bundle_cost_matrix!(
            greedy_sol,
            instance,
            bundle_idx,
            mode_selector;
            cost_fn=compute_ttg_edge_incremental_cost,
            buffer=buffer,
        )
        greedy_snapshot = Dict{Tuple{Int,Int},Float64}()
        for (u, v) in bundle_arcs
            greedy_snapshot[(u, v)] = ttg.cost_matrix[u, v]
        end
        greedy_path = bundle_shortest_path(instance, origin, destination)
        if isempty(greedy_path)
            throw(
                ArgumentError(
                    "No feasible greedy path for bundle $bundle_idx: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id), " *
                    "no elementary path from origin to destination",
                ),
            )
        end
        add_bundle_path!(greedy_sol, instance, bundle_idx, greedy_path; mode_selector)

        # Lower-bound strategy: relaxed costs against empty lb_sol path state.
        # This overwrites ttg.cost_matrix in place.
        update_bundle_cost_matrix!(
            lb_sol,
            instance,
            bundle_idx,
            mode_selector;
            cost_fn=compute_ttg_edge_lower_bound_cost,
            buffer=buffer,
        )
        lb_path = bundle_shortest_path(instance, origin, destination)
        if isempty(lb_path)
            throw(
                ArgumentError(
                    "No feasible lower-bound path for bundle $bundle_idx: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id), " *
                    "no elementary path from origin to destination",
                ),
            )
        end
        add_bundle_path!(lb_sol, instance, bundle_idx, lb_path; mode_selector)

        # Mixed strategy: convex blend of the two cost matrices.
        w_greedy = i / B
        w_lb = 1 - i / B
        for (u, v) in bundle_arcs
            lb_cost = ttg.cost_matrix[u, v]
            greedy_cost = greedy_snapshot[(u, v)]
            ttg.cost_matrix[u, v] = if isinf(greedy_cost) || isinf(lb_cost)
                Inf
            else
                w_greedy * greedy_cost + w_lb * lb_cost
            end
        end
        mix_path = bundle_shortest_path(instance, origin, destination)
        if isempty(mix_path)
            throw(
                ArgumentError(
                    "No feasible mixed path for bundle $bundle_idx: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id), " *
                    "no elementary path from origin to destination",
                ),
            )
        end
        add_bundle_path!(mixed_sol, instance, bundle_idx, mix_path; mode_selector)
    end

    return (; mixed=mixed_sol, greedy=greedy_sol, lower_bound=lb_sol)
end

"""
$TYPEDSIGNATURES

Return the minimum-`cost` solution among `candidates` that satisfies
`is_feasible(sol, instance)`. Throws `ArgumentError` if none are feasible.
Used by [`mix_greedy_heuristic`](@ref) to pick among the three solutions returned by
`mix_greedy_and_lower_bound`.
"""
function choose_best_feasible(
    candidates::AbstractVector{<:SolutionState}, instance::Instance
)
    feasible = filter(s -> is_feasible(s, instance), candidates)
    if isempty(feasible)
        throw(ArgumentError("no feasible candidate among $(length(candidates)) solutions"))
    end
    return argmin(cost, feasible)
end

"""
$TYPEDSIGNATURES

Run [`mix_greedy_and_lower_bound`](@ref) and return the best of its three
candidates via [`choose_best_feasible`](@ref). `start` is forwarded to
[`mix_greedy_and_lower_bound`](@ref) as the seed solution for all candidates.
Set `show_progress=false` to hide the progress bar.
"""
function mix_greedy_heuristic(
    instance::Instance;
    mode_selector::AbstractModeSelector=CheapestMode(),
    start::SolutionState=SolutionState(instance),
    show_progress::Bool=true,
)
    candidates = mix_greedy_and_lower_bound(instance; mode_selector, start, show_progress)
    return choose_best_feasible(collect(values(candidates)), instance)
end
