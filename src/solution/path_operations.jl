"""
$TYPEDSIGNATURES

Project a node code from the `TravelTimeGraph` to a node code in the `TimeSpaceGraph` for a
specific order.
The projection converts the graph-specific time `τ` (budget or elapsed) into absolute time `t` in
the `TimeSpaceGraph`.

# Time Projection Formulas
- If `is_date_arrival = true`: `t = deadline - τ`
- If `is_date_arrival = false`: `t = release + τ`

Throws a `DomainError` if the resulting `t` is outside the instance time horizon
`[1, time_horizon_length]`.
"""
function project_to_time_space_graph(
    ttg_node_code::Int, order::Order{is_date_arrival}, instance::Instance
) where {is_date_arrival}
    cache = instance.index_cache
    snode = cache.ttg_code_to_spatial_code[ttg_node_code]
    τ = cache.ttg_code_to_tau[ttg_node_code]

    if is_date_arrival
        t = order.time_step - τ
    else
        t = order.time_step + τ
    end

    if !(1 <= t <= instance.time_horizon_length)
        if instance.time_space_graph.wrap_time
            if t > instance.time_horizon_length
                t = t - instance.time_horizon_length
            else
                t = t + instance.time_horizon_length
            end
        else
            throw(
                DomainError(
                    t,
                    "Projected time step out of bounds (τ=$(τ), t=$(t)) for order $(order) and node code $(ttg_node_code)",
                ),
            )
        end
    end

    tsg_code = cache.spatial_code_and_time_to_tsg_code[snode, t]
    # spatial_code_and_time_to_tsg_code stores 0 where no TSG node exists at (snode, t). Valid
    # projections always land on an existing node (the TSG has a timed copy of
    # every network node for every t in 1:time_horizon_length), so a 0 here means
    # a broken invariant, not normal flow. Throw a clear error instead of letting
    # 0 propagate into downstream graph lookups.
    iszero(tsg_code) && throw(
        DomainError(
            (snode, t),
            "No TimeSpaceGraph node at (spatial=$(snode), t=$(t)) for ttg_node_code=$(ttg_node_code), τ=$(τ)",
        ),
    )
    return tsg_code
end

# Helper to check if an arc is a shortcut arc.
_is_shortcut_arc(::AbstractNetworkArc) = false
function _is_shortcut_arc(arc::NetworkArc{ShortcutArcCost,K}) where {K}
    return travel_time_steps(arc) == 0
end

"""
$TYPEDSIGNATURES

Remove leading or trailing shortcut nodes from a TTG path, depending on the graph's time semantics.
"""
function _remove_shortcuts_from_path!(path::Vector{Int}, ttg::TravelTimeGraph)
    # Arrival-based graphs carry shortcuts at the front (strip the leading node,
    # keeping the first timed node); elapsed-time graphs carry them at the back
    # (pop the trailing node).
    from_front = is_date_arrival(ttg)
    while length(path) >= 2
        src, dst = from_front ? (path[1], path[2]) : (path[end - 1], path[end])
        u_label = MetaGraphsNext.label_for(ttg.graph, src)
        v_label = MetaGraphsNext.label_for(ttg.graph, dst)
        haskey(ttg.graph, u_label, v_label) || break
        arc = ttg.graph[u_label, v_label]
        # Only strip a shortcut arc that stays on the same spatial node.
        (_is_shortcut_arc(arc) && u_label[1] == v_label[1]) || break
        from_front ? deleteat!(path, 1) : pop!(path)
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Walk each `(order, path-edge)` pair of `bundle` along `path`, resolve the
time-space edge `(u_tsg, v_tsg)` and its network `arc`, and accumulate the
`Float64` deltas returned by `f(edge, arc, order)`. Shared by
[`add_bundle_path!`](@ref) and [`remove_bundle_path!`](@ref).

Each `(order, path-edge)` pair is visited once and `f` is called per pair, so
commits and removals stay one-for-one. Under `wrap_time` a cyclic spatial path
can make one order, or two orders of the bundle, project onto the same TSG edge:
the deltas are still a plain additive sum, with no per-edge grouping. Such paths
are infeasible for [`is_feasible`](@ref) but remain valid for accounting.
"""
function _foreach_path_edge(f, instance::Instance, bundle::Bundle, path::Vector{Int})
    cache = instance.index_cache
    delta = 0.0
    for order in bundle.orders
        for k in 1:(length(path) - 1)
            arc = ttg_edge_arc(cache, path[k], path[k + 1])
            if isnothing(arc)
                g = instance.travel_time_graph.graph
                u_label = MetaGraphsNext.label_for(g, path[k])
                v_label = MetaGraphsNext.label_for(g, path[k + 1])
                throw(
                    ArgumentError(
                        "TTG edge ($u_label, $v_label) of bundle " *
                        "$(bundle.origin_id) -> $(bundle.destination_id) has no network arc",
                    ),
                )
            end
            u_tsg = project_to_time_space_graph(path[k], order, instance)
            v_tsg = project_to_time_space_graph(path[k + 1], order, instance)
            delta += f((u_tsg, v_tsg), arc, order)
        end
    end
    return delta
end

"""
$TYPEDSIGNATURES

Add bundle path `path` for bundle `bundle_idx` to the solution `current_solution`.
This updates the `bundle_paths` and the `assignments` for all arcs along the path.

Returns the cost increase produced by adding `path` (a non-negative `Float64`).
The increase is the sum, over every path edge, of the arc-cost change (via
`_update_single_assignment_cost!`) plus the change in the head node's cost.
"""
function add_bundle_path!(
    current_solution::Solution{C},
    instance::Instance,
    bundle_idx::Int,
    path::Vector{Int};
    mode_selector::AbstractModeSelector=CheapestMode(),
    packing::Symbol=:frozen,
) where {C}
    # Remove potential shortcut edges before storing the path (TTG may contain shortcuts).
    _remove_shortcuts_from_path!(path, instance.travel_time_graph)
    current_solution.bundle_paths[bundle_idx] = path
    bundle = instance.bundles[bundle_idx]

    return _commit_bundle_path!(
        current_solution.assignments, instance, bundle, path, mode_selector, packing
    )
end

"""
$TYPEDSIGNATURES

Commit every order of `bundle` along the already cleaned `path` into
`assignments`, one `(order, edge)` at a time, and return the cost increase.
Each commit receives a single order, whose commodities are sorted descending by
size. Shared by [`add_bundle_path!`](@ref) and the `Solution(bundle_paths, instance)`
constructor, so both pack identically.
"""
function _commit_bundle_path!(
    assignments::Dict{Tuple{Int,Int},<:AbstractArcAssignment},
    instance::Instance,
    bundle::Bundle,
    path::Vector{Int},
    mode_selector::AbstractModeSelector,
    packing::Symbol,
)
    cache = instance.index_cache
    return _foreach_path_edge(instance, bundle, path) do edge, arc, order
        sv = cache.tsg_code_to_spatial_code[edge[2]]
        return _add_order_to_assignment!(
            assignments,
            edge,
            arc,
            order.commodities,
            mode_selector,
            cache.spatial_code_to_node_cost,
            sv;
            packing,
        )
    end
end

"""
$TYPEDSIGNATURES

Reverse the effect of `add_bundle_path!` for bundle `bundle_idx`. Drops the
bundle's commodities from every TSG edge along the stored path, then clears
`bundle_paths[bundle_idx]`. Returns the cost decrease produced by the removal
(a non-positive `Float64` whose magnitude equals the dropped arc and head-node
cost contribution of the bundle on its path). Returns `0.0` when the bundle
path is already empty.

Per-edge details:
- On `BinPackingArcCost` edges, bins are recomputed from scratch via
  `compute_bin_assignments`, so the stored `bins` and `cost` reflect the
  reduced commodity set.
- On `LinearArcCost` edges, `cost` is recomputed via `evaluate`.
- Commodities are matched by `==`. By construction (see
  `build_instance`), two bundles with different `(origin_id, destination_id,
  group_key)` cannot share `==`-equal commodities, so the match is
  unambiguous across bundles.
- For `MultiAssignment` edges, modes are scanned in order. Each commodity is
  dropped from the first mode that contains it, which is always the mode
  where `add_bundle_path!` placed it (no other bundle's commodities can
  alias under `==`).

Assignment dict entries are kept even when their commodity vector goes to
zero, so subsequent reinsertion can reuse them without re-keying. An entry
whose commodities are empty contributes `0` to `cost(sol)` via
`_update_single_assignment_cost!`.

Throws `ArgumentError` if any of the bundle's commodities are not found on
the expected TSG edges. That should never happen when the bundle's stored
path is consistent with how it was added.
"""
function remove_bundle_path!(
    current_solution::Solution{C}, instance::Instance, bundle_idx::Int
) where {C}
    path = current_solution.bundle_paths[bundle_idx]
    isempty(path) && return 0.0
    bundle = instance.bundles[bundle_idx]
    cache = instance.index_cache

    cost_delta = _foreach_path_edge(instance, bundle, path) do edge, arc, order
        assignment = current_solution.assignments[edge]
        sv = cache.tsg_code_to_spatial_code[edge[2]]
        return _remove_commodities_from_assignment!(
            assignment, arc, order.commodities, cache.spatial_code_to_node_cost, sv
        )
    end

    current_solution.bundle_paths[bundle_idx] = Int[]
    return cost_delta
end

"""
    Solution(bundle_paths, instance; mode_selector=CheapestMode())

Construct a `Solution` from bundle paths and an instance.
This constructor precomputes commodity distributions on arcs, bin-packing results, and total cost.
Throws an `ArgumentError` if a path uses an edge that has no network arc.
"""
function Solution(
    bundle_paths::Vector{Vector{Int}},
    instance::Instance{<:Bundle{<:Order{IDA,I}}};
    mode_selector::AbstractModeSelector=CheapestMode(),
) where {IDA,I}
    bundles = instance.bundles

    C = LightCommodity{I}
    assignments = Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}()

    # Clean paths (remove TTG shortcut edges) before projecting
    cleaned_paths = [copy(p) for p in bundle_paths]
    for (bundle_idx, ttg_path) in enumerate(cleaned_paths)
        _remove_shortcuts_from_path!(ttg_path, instance.travel_time_graph)
        _commit_bundle_path!(
            assignments, instance, bundles[bundle_idx], ttg_path, mode_selector, :frozen
        )
    end

    return Solution{C}(cleaned_paths, assignments)
end
