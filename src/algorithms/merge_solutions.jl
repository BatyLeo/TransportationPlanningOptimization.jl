"""
$TYPEDSIGNATURES

Stitch `sub_solution` (defined on `sub_instance`) back onto `full_solution`
(defined on `full_instance`) and return a freshly constructed `Solution` on
`full_instance`.

For each bundle of `full_instance`:

- If a matching bundle exists in `sub_instance` (matched by
  `(origin_id, destination_id)`), the path stored in `sub_solution` is
  projected back into the full TTG via spatial labels and used as that
  bundle's path in the merged solution.
- Otherwise, `full_solution`'s path for that bundle is reused.

The merged solution is then built in one batched pass via the
`Solution(bundle_paths, instance)` constructor, so each arc's commodities
are packed exactly once with their final commodity set. This avoids the
quadratic-in-arc-load FFD-repack cost of the previous bundle-by-bundle
`remove_bundle_path!` / `add_bundle_path!` loop.

The caller is expected to have run `lower_bound_filtering` (or similar) on
`full_solution` first, so every bundle of `full_instance` already has a path.

Bundles are matched on `(origin_id, destination_id, group)`, where `group` is
the bundle's `group_by` key (`nothing` under the default grouping). This
supports instances built with a non-default `Instance(...; group_by=...)`, as
long as no two bundles in the same instance collide on that full triple.
Throws `ArgumentError` if either instance has two bundles with identical
`(origin_id, destination_id, group)`.
"""
function merge_solutions(
    full_solution::Solution,
    sub_solution::Solution,
    full_instance::Instance,
    sub_instance::Instance,
)
    full_ttg = full_instance.travel_time_graph
    sub_ttg = sub_instance.travel_time_graph

    sub_idx_of_bundle = Dict{Tuple{String,String,Any},Int}()
    for (i, b) in enumerate(sub_instance.bundles)
        key = (b.origin_id, b.destination_id, b.group)
        if haskey(sub_idx_of_bundle, key)
            throw(
                ArgumentError(
                    "merge_solutions requires bundles unique on " *
                    "(origin, destination, group). sub_instance has multiple " *
                    "bundles for $(key) (indices $(sub_idx_of_bundle[key]) and " *
                    "$(i)). Two bundles share the same origin, destination, and " *
                    "`group_by` key, so the merge cannot disambiguate them.",
                ),
            )
        end
        sub_idx_of_bundle[key] = i
    end

    fused_paths = Vector{Vector{Int}}(undef, length(full_instance.bundles))
    seen_full_keys = Set{Tuple{String,String,Any}}()
    for (full_i, bundle) in enumerate(full_instance.bundles)
        key = (bundle.origin_id, bundle.destination_id, bundle.group)
        if key in seen_full_keys
            throw(
                ArgumentError(
                    "merge_solutions requires bundles unique on " *
                    "(origin, destination, group). full_instance has multiple " *
                    "bundles for $(key) (second occurrence at index $(full_i)). " *
                    "See `sub_instance` error message above for context.",
                ),
            )
        end
        push!(seen_full_keys, key)

        fused_paths[full_i] = if haskey(sub_idx_of_bundle, key)
            sub_path = sub_solution.bundle_paths[sub_idx_of_bundle[key]]
            # Project sub-TTG codes back to full-TTG codes via spatial label
            Int[
                MetaGraphsNext.code_for(
                    full_ttg.graph, MetaGraphsNext.label_for(sub_ttg.graph, code)
                ) for code in sub_path
            ]
        else
            full_solution.bundle_paths[full_i]
        end
    end

    return Solution(fused_paths, full_instance)
end
