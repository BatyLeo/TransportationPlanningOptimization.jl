"""
$TYPEDSIGNATURES

Stitch `sub_solution` (defined on `sub_instance`) back onto `full_solution`
(defined on `full_instance`). For each bundle of `full_instance`:

- If a matching bundle exists in `sub_instance` (matched by
  `(origin_id, destination_id)`), the path stored in `sub_solution` is
  projected back into the full TTG via spatial labels and substituted into
  `full_solution` via `remove_bundle_path!` + `add_bundle_path!`.
- Otherwise, `full_solution`'s path is left untouched.

Returns the modified `full_solution`. The caller is expected to have run
`lower_bound_filtering!` (or similar) on `full_solution` first, so every
bundle already has a path.

Assumes the default `group_by` (no extra grouping). Two bundles in the same
instance must therefore have distinct `(origin_id, destination_id)` pairs.
Throws `ArgumentError` if either instance violates this assumption.
"""
function merge_solutions(
    full_solution::Solution,
    sub_solution::Solution,
    full_instance::Instance,
    sub_instance::Instance,
)
    full_ttg = full_instance.travel_time_graph
    sub_ttg = sub_instance.travel_time_graph

    sub_idx_of_bundle = Dict{Tuple{String,String},Int}()
    for (i, b) in enumerate(sub_instance.bundles)
        key = (b.origin_id, b.destination_id)
        if haskey(sub_idx_of_bundle, key)
            throw(
                ArgumentError(
                    "merge_solutions only supports OD-unique bundles. " *
                    "sub_instance has multiple bundles for OD $(key) " *
                    "(indices $(sub_idx_of_bundle[key]) and $(i)). This can " *
                    "happen when `Instance(...; group_by=...)` is used with a " *
                    "non-default key. To support that case, the merge would " *
                    "need to key on the full `(origin, destination, group)` " *
                    "tuple instead of `(origin, destination)`.",
                ),
            )
        end
        sub_idx_of_bundle[key] = i
    end

    seen_full_keys = Set{Tuple{String,String}}()
    for (full_i, bundle) in enumerate(full_instance.bundles)
        key = (bundle.origin_id, bundle.destination_id)
        if key in seen_full_keys
            throw(
                ArgumentError(
                    "merge_solutions only supports OD-unique bundles. " *
                    "full_instance has multiple bundles for OD $(key) " *
                    "(second occurrence at index $(full_i)). See `sub_instance` " *
                    "error message above for context.",
                ),
            )
        end
        push!(seen_full_keys, key)
        haskey(sub_idx_of_bundle, key) || continue
        sub_i = sub_idx_of_bundle[key]
        sub_path = sub_solution.bundle_paths[sub_i]
        # Project sub-TTG codes back to full-TTG codes via spatial label
        full_path = Int[
            MetaGraphsNext.code_for(
                full_ttg.graph, MetaGraphsNext.label_for(sub_ttg.graph, code)
            ) for code in sub_path
        ]
        remove_bundle_path!(full_solution, full_instance, full_i)
        # `remove_bundle_path!` re-packs the affected arcs with FFD-union, so the
        # re-add stays on FFD-union to keep the merged solution self-consistent
        # (frozen packing is order-dependent and would not match the re-pack).
        add_bundle_path!(
            full_solution, full_instance, full_i, full_path; packing=:ffd_union
        )
    end
    return full_solution
end
