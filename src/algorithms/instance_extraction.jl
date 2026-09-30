"""
$TYPEDSIGNATURES

Build a sub-instance that retains only bundles whose filtering path are not direct paths.
The returned [`NetworkGraph`](@ref) keeps every intermediate node (`node_type == :other`)
from the original network so consolidation hubs remain available to the retained bundles,
and drops only `:origin` and `:destination` nodes that no kept bundle references. The
[`TravelTimeGraph`](@ref) and [`TimeSpaceGraph`](@ref) are rebuilt on that
subgraph so the sub-instance is self-consistent.

The returned `Instance` shares the original bundle and commodity objects (no
deep copy). Only the `bundles` vector and the three graph layers are new.

If no bundles survive filtering, an info message is logged and the returned instance
has an empty `bundles` vector.
"""
function extract_filtered_instance(instance::Instance, filtering_solution::Solution)
    keep_idxs = findall(p -> length(p) > 2, filtering_solution.bundle_paths)

    if isempty(keep_idxs)
        @info "All bundles are fixed by filtering, the sub-instance is empty"
        return Instance(;
            bundles=eltype(instance.bundles)[],
            network_graph=instance.network_graph,
            time_horizon_length=instance.time_horizon_length,
            time_step=instance.time_step,
            time_step_to_date=instance.time_step_to_date,
            time_space_graph=instance.time_space_graph,
            travel_time_graph=instance.travel_time_graph,
            # The degenerate case reuses the original graphs verbatim, so the
            # original cache (built from those same graphs) stays valid.
            index_cache=instance.index_cache,
        )
    end

    kept_bundles = instance.bundles[keep_idxs]
    kept_origin_ids = Set(b.origin_id for b in kept_bundles)
    kept_destination_ids = Set(b.destination_id for b in kept_bundles)

    # Keep every intermediate node unconditionally so consolidation hubs remain
    # available to kept bundles. Filter out only :origin / :destination nodes
    # that no kept bundle references.
    ng = instance.network_graph.graph
    kept_codes = Int[]
    for label in MetaGraphsNext.labels(ng)
        node = ng[label]
        if node.node_type == :origin
            label in kept_origin_ids || continue
        elseif node.node_type == :destination
            label in kept_destination_ids || continue
        end
        push!(kept_codes, MetaGraphsNext.code_for(ng, label))
    end
    sub_g, _ = Graphs.induced_subgraph(ng, kept_codes)
    sub_network = NetworkGraph(sub_g)

    sub_tsg = TimeSpaceGraph(
        sub_network,
        instance.time_horizon_length;
        wrap_time=instance.time_space_graph.wrap_time,
    )
    sub_ttg = TravelTimeGraph(sub_network, kept_bundles)

    return Instance(;
        bundles=kept_bundles,
        network_graph=sub_network,
        time_horizon_length=instance.time_horizon_length,
        time_step=instance.time_step,
        time_step_to_date=instance.time_step_to_date,
        time_space_graph=sub_tsg,
        travel_time_graph=sub_ttg,
        index_cache=build_index_cache(sub_network, sub_ttg, sub_tsg),
    )
end

"""
$TYPEDSIGNATURES

Build a fresh `Solution` on `sub_instance` that reserves the capacity and
cost of every bundle of `full_instance` that `extract_filtered_instance`
dropped (the direct-path bundles, i.e. `filtering_sol.bundle_paths[i]` of
length 2).

For each dropped bundle, commits its full-instance path load onto the
matching `sub_instance` time-space edges (via `_foreach_path_edge`), skipping
edges that were pruned from `sub_instance`. Does not set `bundle_paths`: the
returned solution is meant as the `start` argument of
[`mix_greedy_and_lower_bound`](@ref), which each candidate then builds on top
of via `deepcopy`.

A dropped bundle whose direct arc is not in `sub_instance` is skipped
entirely, since it cannot contend with kept bundles for capacity there.
"""
function preload_filtered_bundles(
    filtering_sol::Solution, full_instance::Instance, sub_instance::Instance
)
    sol = Solution(sub_instance)
    full_tsg = full_instance.time_space_graph.graph
    sub_tsg = sub_instance.time_space_graph.graph
    sub_cache = sub_instance.index_cache

    dropped_idxs = findall(p -> length(p) <= 2, filtering_sol.bundle_paths)
    for i in dropped_idxs
        bundle = full_instance.bundles[i]
        _foreach_path_edge(
            full_instance, bundle, filtering_sol.bundle_paths[i]
        ) do edge, _, order
            u_label = MetaGraphsNext.label_for(full_tsg, edge[1])
            v_label = MetaGraphsNext.label_for(full_tsg, edge[2])
            MetaGraphsNext.haskey(sub_tsg, u_label, v_label) || return 0.0

            u_sub = MetaGraphsNext.code_for(sub_tsg, u_label)
            v_sub = MetaGraphsNext.code_for(sub_tsg, v_label)
            sub_arc = sub_tsg[u_label, v_label]
            sv_sub = sub_cache.tsg_code_to_spatial_code[v_sub]

            return _add_order_to_assignment!(
                sol.assignments,
                (u_sub, v_sub),
                sub_arc,
                order.commodities,
                CheapestMode(),
                sub_cache.spatial_code_to_node_cost,
                sv_sub,
            )
        end
    end
    return sol
end
