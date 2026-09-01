# Shared loop for lower_bound and lower_bound_filtering: sort bundles by
# decreasing max single-commodity size (matching greedy_heuristic), compute
# each bundle's shortest path against the empty solution using `cost_fn`,
# and insert it.
function _shortest_path_assign!(
    current_solution::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector,
    cost_fn,
    label::AbstractString,
)
    ttg = instance.travel_time_graph
    # Initialize an empty solution and a reusable buffer
    empty_sol = Solution(instance)
    buffer = BinPackingBuffer()
    # Sort bundles by max_pack_size
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    @showprogress for i in sorted_indices
        # Compute (and update inplace) the cost matrix for inserting bundle i into an empty solution
        update_bundle_cost_matrix!(
            empty_sol, instance, i, mode_selector; cost_fn=cost_fn, buffer=buffer
        )
        origin = ttg.origin_codes[i]     # origin node of bundle i in ttg
        dest = ttg.destination_codes[i]  # destination node of bundle i in ttg
        # Compute the shortest path between origin and dest
        parents, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=dest)
        path = trace_path(parents, origin, dest)
        # Throw an error if no path was found (i.e. there is no feasible path)
        if isempty(path)
            bundle = instance.bundles[i]
            max_steps = maximum(o.max_transit_steps for o in bundle.orders)
            throw(
                ArgumentError(
                    "No feasible $label path for bundle $i: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id), " *
                    "max_transit_steps=$(max_steps), " *
                    "forbidden_nodes=$(bundle.forbidden_nodes), " *
                    "forbidden_arcs=$(bundle.forbidden_arcs)",
                ),
            )
        end
        # Insert bundle i using computed path above
        add_bundle_path!(current_solution, instance, i, path; mode_selector)
    end
    return current_solution
end

"""
$TYPEDSIGNATURES

For each bundle, find the cheapest path under the relaxed lower-bound cost
(fractional bin counts on `BinPackingArcCost` arcs) and insert it into a fresh
`Solution`. Bundles are processed in input order, but every bundle's cost matrix
is computed against the *empty* solution, so paths are independent of one another.
The result is a valid lower bound when costs are linear in total volume per bundle,
and a near-tight bound otherwise.
"""
function lower_bound(instance::Instance, mode_selector::AbstractModeSelector=CheapestMode())
    sol = Solution(instance)
    return _shortest_path_assign!(
        sol, instance, mode_selector, compute_ttg_edge_lower_bound_cost, "lower-bound"
    )
end

"""
$TYPEDSIGNATURES

Run the lower-bound filtering pre-pass. Computes, for each bundle independently,
the cheapest path under the hybrid relaxed cost from
`compute_ttg_edge_filtering_cost`. Bundles whose result is the direct arc
(path length 2) are the ones `extract_filtered_instance` will drop.
"""
function lower_bound_filtering(
    instance::Instance, mode_selector::AbstractModeSelector=CheapestMode()
)
    sol = Solution(instance)
    return _shortest_path_assign!(
        sol, instance, mode_selector, compute_ttg_edge_filtering_cost, "filtering"
    )
end
