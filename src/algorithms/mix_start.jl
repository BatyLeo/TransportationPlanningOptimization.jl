"""
$TYPEDSIGNATURES

Build three solutions in a single sweep over bundles (sorted by
`max_pack_size` descending): pure greedy, pure lower bound, and a mixed
solution whose Dijkstra cost matrix blends the two strategies with weights
that shift toward greedy as more bundles are placed.

Returns `(; mixed, greedy, lower_bound)`. All three solutions are independent
`Solution` objects, suitable for `cost`, `is_feasible`, and downstream local
search.

The blend formula matches STP (`mix_greedy_and_lower_bound!` in
`ShipperTransportationPlanning.jl/src/Algorithms/miscellaneous.jl:835`):

```
mix_cost = (i / B) * greedy_cost + (B - i / B) * lb_cost
```

where `i` is the 1-indexed iteration and `B` is the total bundle count. This
is reproduced verbatim from STP. The formula is suspected to be a typo (a
natural convex blend would be `(i / B) + (1 - i / B)`), but Dijkstra is
invariant to a global scalar on the cost matrix, so the unnormalised form is
monotonically equivalent to `(i / B^2) * greedy + (1 - i / B^2) * lb`. The LB
component dominates throughout and the greedy share grows quadratically.

The sweep relies on the shared `ttg.cost_matrix`: each iteration calls
`update_bundle_cost_matrix!` with the greedy `cost_fn`, snapshots the bundle's
arc entries, calls it again with the lower-bound `cost_fn` (which overwrites),
then blends in place on the bundle's arcs only using the snapshot.

The `packing::Symbol = :frozen` keyword selects bin-packing semantics on the
greedy half: it is forwarded to the greedy cost matrix and to the greedy and
mixed commits (so those two solutions are self-consistent). See
[`greedy_heuristic`](@ref) for the `:frozen` versus `:ffd_union` distinction.
The lower-bound strategy is a fractional relaxation and is unaffected, so the
`lb_sol` commit keeps `:ffd_union`.
"""
function mix_greedy_and_lower_bound(
    instance::Instance;
    mode_selector::AbstractModeSelector=CheapestMode(),
    packing::Symbol=:frozen,
)
    ttg = instance.travel_time_graph
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    B = length(instance.bundles)

    greedy_sol = Solution(instance)
    lb_sol = Solution(instance)
    mixed_sol = Solution(instance)

    # One bin-packing scratch buffer reused across every bundle and arc.
    buffer = BinPackingBuffer()

    @showprogress for (i, bundle_idx) in enumerate(sorted_indices)
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
            packing=packing,
        )
        greedy_snapshot = Dict{Tuple{Int,Int},Float64}()
        for (u, v) in bundle_arcs
            greedy_snapshot[(u, v)] = ttg.cost_matrix[u, v]
        end
        greedy_parents, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix)
        greedy_path = trace_path(greedy_parents, origin, destination)
        if isempty(greedy_path)
            throw(
                ArgumentError(
                    "No feasible greedy path for bundle $bundle_idx: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id)",
                ),
            )
        end
        add_bundle_path!(
            greedy_sol, instance, bundle_idx, greedy_path; mode_selector, packing
        )

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
        lb_parents, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix)
        lb_path = trace_path(lb_parents, origin, destination)
        if isempty(lb_path)
            throw(
                ArgumentError(
                    "No feasible lower-bound path for bundle $bundle_idx: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id)",
                ),
            )
        end
        add_bundle_path!(
            lb_sol, instance, bundle_idx, lb_path; mode_selector, packing=:ffd_union
        )

        # Blend: ttg.cost_matrix now holds LB costs. Apply the blend on the
        # bundle's arcs only, using the cached greedy snapshot. Reproduces
        # STP's blend formula verbatim (not the natural convex combination).
        w_greedy = i / B
        w_lb = B - i / B
        for (u, v) in bundle_arcs
            lb_cost = ttg.cost_matrix[u, v]
            greedy_cost = greedy_snapshot[(u, v)]
            ttg.cost_matrix[u, v] = w_greedy * greedy_cost + w_lb * lb_cost
        end
        mix_parents, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix)
        mix_path = trace_path(mix_parents, origin, destination)
        if isempty(mix_path)
            throw(
                ArgumentError(
                    "No feasible mixed path for bundle $bundle_idx: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id)",
                ),
            )
        end
        add_bundle_path!(mixed_sol, instance, bundle_idx, mix_path; mode_selector, packing)
    end

    return (; mixed=mixed_sol, greedy=greedy_sol, lower_bound=lb_sol)
end

"""
$TYPEDSIGNATURES

Return the minimum-`cost` solution among `candidates` that satisfies
`is_feasible(sol, instance)`. Throws `ArgumentError` if none are feasible.
Used by `solve_filtered` to pick among the three solutions returned by
`mix_greedy_and_lower_bound`.
"""
function choose_best_feasible(candidates::AbstractVector{<:Solution}, instance::Instance)
    feasible = filter(s -> is_feasible(s, instance), candidates)
    if isempty(feasible)
        throw(ArgumentError("no feasible candidate among $(length(candidates)) solutions"))
    end
    return argmin(cost, feasible)
end
