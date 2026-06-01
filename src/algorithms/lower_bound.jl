"""
$TYPEDSIGNATURES

For each bundle, find the cheapest path under the relaxed lower-bound cost
(fractional bin counts on `BinPackingArcCost` arcs) and append it to
`current_solution`. Bundles are processed in input order, but every bundle's
cost matrix is computed against the *empty* solution, so paths are independent
of one another. The result is a valid lower bound when costs are linear in
total volume per bundle, and a near-tight bound otherwise.
"""
function lower_bound!(
    current_solution::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    ttg = instance.travel_time_graph
    empty_sol = Solution(instance)
    # Insert bundles in decreasing max-pack-size order, matching
    # `greedy_heuristic`. The LB paths themselves are computed against
    # `empty_sol` and therefore independent of insertion order, but the order
    # in which paths are added to `current_solution` affects shared-arc bin
    # packing in the resulting solution. Sorting by `max_pack_size` keeps the
    # post-insertion `cost(lb_sol)` competitive with greedy.
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    # One bin-packing scratch buffer reused across every bundle and arc.
    buffer = BinPackingBuffer()
    @showprogress for i in sorted_indices
        update_bundle_cost_matrix!(
            empty_sol,
            instance,
            i,
            mode_selector;
            cost_fn=compute_ttg_edge_lower_bound_cost,
            buffer=buffer,
        )
        origin = ttg.origin_codes[i]
        dest = ttg.destination_codes[i]
        res = Graphs.dijkstra_shortest_paths(ttg.graph, origin, ttg.cost_matrix)
        path = Graphs.enumerate_paths(res, dest)
        if isempty(path)
            bundle = instance.bundles[i]
            max_steps = maximum(o.max_transit_steps for o in bundle.orders)
            throw(
                ArgumentError(
                    "No feasible lower-bound path for bundle $i: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id), " *
                    "max_transit_steps=$(max_steps), " *
                    "forbidden_nodes=$(bundle.forbidden_nodes), " *
                    "forbidden_arcs=$(bundle.forbidden_arcs)",
                ),
            )
        end
        add_bundle_path!(current_solution, instance, i, path; mode_selector)
    end
    return current_solution
end

"""
$TYPEDSIGNATURES

Convenience wrapper that creates an empty `Solution` and runs `lower_bound!`.
"""
function lower_bound(instance::Instance, mode_selector::AbstractModeSelector=CheapestMode())
    sol = Solution(instance)
    lower_bound!(sol, instance, mode_selector)
    return sol
end

"""
$TYPEDSIGNATURES

Like `compute_ttg_edge_lower_bound_cost`, but on the bundle's direct arc
(spatial endpoints equal to `bundle.origin_id` / `bundle.destination_id`) it
charges the *integer* bin count (via `incremental_cost`). The result is the
cost a bundle would pay if it shared bins for free on every multi-hop arc but
paid for its own bins on its direct route. Path lengths of 2 (origin to
destination) after this update mean the relaxed optimum is the direct arc,
which is the signal used by `extract_filtered_instance`.

# Note on direct-arc detection

This implementation detects a direct arc by spatial-endpoint equality with
the routed bundle's `(origin_id, destination_id)`. The Renault reference
implementation (`Algorithms/Utils/lb_utils.jl:lb_filtering_transport_units`)
uses an arc-type tag instead (`arcData.type == :direct`), which is a property
of the arc itself, independent of which bundle is being routed.

The two rules agree when each bundle has at most one direct arc and no
`:direct`-typed arc exists between non-matching endpoints. This holds on the
inbound CSVs in `test/public/`. They diverge once the network models multiple
`:direct`-typed arcs not endpoint-matching the routed bundle, in which case
Renault charges integer bins on all of them for the routed bundle, while this
implementation charges integer only on the bundle's specific OD pair.

A future task can expose `is_direct_for(arc, bundle)` dispatched on
`AbstractNetworkArc` to make the rule data-driven once the package gains an
arc-type taxonomy. Out of scope for now.
"""
function compute_ttg_edge_filtering_cost(
    current_solution::Solution{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
) where {C}
    # Filtering is a lower-bound pre-pass, out of scope for frozen packing.
    # `packing` is accepted only for cost_fn signature uniformity (no effect).
    u_id = MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)[1]
    v_id = MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code)[1]
    if u_id == bundle.origin_id && v_id == bundle.destination_id
        return compute_ttg_edge_incremental_cost(
            current_solution,
            instance,
            bundle,
            u_ttg_code,
            v_ttg_code,
            mode_selector;
            buffer,
        )
    else
        return compute_ttg_edge_lower_bound_cost(
            current_solution,
            instance,
            bundle,
            u_ttg_code,
            v_ttg_code,
            mode_selector;
            buffer,
        )
    end
end

"""
$TYPEDSIGNATURES

Run the lower-bound filtering pre-pass. Computes, for each bundle independently,
the cheapest path under the hybrid relaxed cost from
`compute_ttg_edge_filtering_cost`. Bundles whose result is the direct arc
(path length 2) are the ones `extract_filtered_instance` will drop.
"""
function lower_bound_filtering!(
    current_solution::Solution,
    instance::Instance,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    ttg = instance.travel_time_graph
    empty_sol = Solution(instance)
    # Max-pack-size decreasing insertion order, matching `greedy_heuristic`
    # and `lower_bound!`. Path selection is order-independent (computed
    # against the empty solution), but the order affects shared-arc bin
    # packing in the resulting solution.
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    # One bin-packing scratch buffer reused across every bundle and arc.
    buffer = BinPackingBuffer()
    @showprogress for i in sorted_indices
        update_bundle_cost_matrix!(
            empty_sol,
            instance,
            i,
            mode_selector;
            cost_fn=compute_ttg_edge_filtering_cost,
            buffer=buffer,
        )
        origin = ttg.origin_codes[i]
        dest = ttg.destination_codes[i]
        res = Graphs.dijkstra_shortest_paths(ttg.graph, origin, ttg.cost_matrix)
        path = Graphs.enumerate_paths(res, dest)
        if isempty(path)
            bundle = instance.bundles[i]
            max_steps = maximum(o.max_transit_steps for o in bundle.orders)
            throw(
                ArgumentError(
                    "No feasible filtering path for bundle $i: " *
                    "$(bundle.origin_id) -> $(bundle.destination_id), " *
                    "max_transit_steps=$(max_steps), " *
                    "forbidden_nodes=$(bundle.forbidden_nodes), " *
                    "forbidden_arcs=$(bundle.forbidden_arcs)",
                ),
            )
        end
        add_bundle_path!(current_solution, instance, i, path; mode_selector)
    end
    return current_solution
end

"""
$TYPEDSIGNATURES

Convenience wrapper that creates an empty `Solution` and runs `lower_bound_filtering!`.
"""
function lower_bound_filtering(
    instance::Instance, mode_selector::AbstractModeSelector=CheapestMode()
)
    sol = Solution(instance)
    lower_bound_filtering!(sol, instance, mode_selector)
    return sol
end
