# Shared loop for lower_bound and lower_bound_filtering: sort bundles by
# decreasing max single-commodity size (matching greedy_heuristic), compute
# each bundle's shortest path against the empty solution using `cost_fn`,
# and insert it. `on_fixed(i, path)` is called for each bundle whose path is its
# direct arc (length 2 after shortcut removal), i.e. the ones filtering fixes.
function _shortest_path_assign!(
    current_solution::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector,
    cost_fn,
    label::AbstractString;
    show_progress::Bool=true,
    on_fixed::Function=(i, path) -> nothing,
)
    ttg = instance.travel_time_graph
    # Initialize an empty solution and a reusable buffer
    empty_sol = Solution(instance)
    buffer = BinPackingBuffer()
    # Sort bundles by max_pack_size
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    @showprogress enabled = show_progress for i in sorted_indices
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
                    "forbidden_arcs=$(bundle.forbidden_arcs)" *
                    (
                        label == "filtering" ?
                        " (capacity may be taken by previously fixed direct bundles)" : ""
                    ),
                ),
            )
        end
        # Insert bundle i using computed path above
        add_bundle_path!(current_solution, instance, i, path; mode_selector)
        length(path) == 2 && on_fixed(i, path)
    end
    return current_solution
end

"""
$TYPEDSIGNATURES

For each bundle, find the cheapest path under the relaxed lower-bound cost
(fractional bin counts on `BinPackingArcCost` arcs) and insert it into a fresh
`Solution`. Bundles are processed in decreasing order of `max_pack_size`, but
every bundle's cost matrix is computed against the *empty* solution, so paths
are independent of one another. Each order is still gated against every arc's
hard capacity on its own (see `_edge_lower_bound_cost`), but orders from
different bundles are priced independently and may jointly overload an arc.
The result is a valid lower bound when costs are linear in total volume per bundle,
and a near-tight bound otherwise.
Set `show_progress=false` to hide the progress bar.
"""
function lower_bound(
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    show_progress::Bool=true,
)
    sol = Solution(instance)
    return _shortest_path_assign!(
        sol,
        instance,
        mode_selector,
        compute_ttg_edge_lower_bound_cost,
        "lower-bound";
        show_progress,
    )
end

"""
$TYPEDSIGNATURES

Run the lower-bound filtering pre-pass. Computes, for each bundle,
the cheapest path under the hybrid relaxed cost from
`compute_ttg_edge_filtering_cost`, still priced against an empty solution.
Bundles whose result is the direct arc (path length 2) are the ones
`extract_filtered_instance` will drop, so they are fixed: an arc already full
of fixed bundles is closed to later bundles, which keeps the fixed bundles
jointly within the hard capacities (unlike [`lower_bound`](@ref)). If a bundle
then has no path left, an `ArgumentError` is thrown. As in `greedy_heuristic`, bundles
are fixed greedily in decreasing `max_pack_size` order, so this can also happen on a
feasible instance whose capacity was taken by earlier fixed bundles.
Set `show_progress=false` to hide the progress bar.
"""
function lower_bound_filtering(
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode();
    show_progress::Bool=true,
)
    sol = Solution(instance)
    # Load of the fixed bundles only, read by the capacity gate (pricing stays
    # against the empty solution).
    fixed = Solution(instance)
    fixed_pairs = Set{Tuple{Int,Int}}()
    cache = instance.index_cache
    function fix!(i, path)
        add_bundle_path!(fixed, instance, i, path; mode_selector)
        push!(
            fixed_pairs,
            (
                cache.ttg_code_to_spatial_code[path[1]],
                cache.ttg_code_to_spatial_code[path[2]],
            ),
        )
        return nothing
    end
    filtering_cost(sol_, inst, bundle, u, v, sel; buffer, packing) =
        if _fits_fixed_load(fixed, fixed_pairs, inst, bundle, u, v, sel, buffer)
            compute_ttg_edge_filtering_cost(sol_, inst, bundle, u, v, sel; buffer, packing)
        else
            Inf
        end
    return _shortest_path_assign!(
        sol,
        instance,
        mode_selector,
        filtering_cost,
        "filtering";
        show_progress,
        on_fixed=fix!,
    )
end
