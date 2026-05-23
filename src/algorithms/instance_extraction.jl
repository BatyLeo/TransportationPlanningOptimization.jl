"""
$TYPEDSIGNATURES

Build a sub-instance that retains only bundles whose filtering path (in
`filtering_solution.bundle_paths`) has more than two nodes (i.e. is not just
`[origin, destination]`). The returned [`NetworkGraph`](@ref) keeps every
intermediate node (`node_type == :other`) from the original network so
consolidation hubs remain available to the retained bundles, and drops only
`:origin` and `:destination` nodes that no kept bundle references. The
[`TravelTimeGraph`](@ref) and [`TimeSpaceGraph`](@ref) are rebuilt on that
subgraph so the sub-instance is self-consistent.

The returned `Instance` shares the original bundle and commodity objects (no
deep copy). Only the `bundles` vector and the three graph layers are new. Field
identifiers like `Bundle.origin_id` / `Bundle.destination_id` (spatial node IDs,
strings) are not reindexed.

If no bundles survive filtering, a warning is emitted and the returned instance
has an empty `bundles` vector. To keep the three graph fields well-typed in
that degenerate case, the original `network_graph`, `travel_time_graph`, and
`time_space_graph` are reused (the `TravelTimeGraph` constructor refuses an
empty bundle vector).
"""
function extract_filtered_instance(instance::Instance, filtering_solution::Solution)
    keep_idxs = findall(p -> length(p) > 2, filtering_solution.bundle_paths)

    if isempty(keep_idxs)
        @warn "extract_filtered_instance: no bundles remain in the sub-instance"
        return Instance(;
            bundles=eltype(instance.bundles)[],
            network_graph=instance.network_graph,
            time_horizon_length=instance.time_horizon_length,
            time_step=instance.time_step,
            time_step_to_date=instance.time_step_to_date,
            time_space_graph=instance.time_space_graph,
            travel_time_graph=instance.travel_time_graph,
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
    )
end
