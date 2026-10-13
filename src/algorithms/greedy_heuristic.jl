"""
$TYPEDSIGNATURES

Build the `ArgumentError` thrown when bundle `bundle_idx` has no path left. `label` names
the step that failed. The message gives the bundle endpoints, its maximum number of
transit steps and its forbidden sets. The path may be blocked by the time budget, the
forbidden constraints or the arc and mode capacities. With `fixed_hint=true`, it also
mentions that capacity may have been taken by previously fixed direct bundles.
"""
function _no_path_error(
    instance::Instance, bundle_idx::Int, label::AbstractString; fixed_hint::Bool=false
)::ArgumentError
    bundle = instance.bundles[bundle_idx]
    max_steps = maximum(o.max_transit_steps for o in bundle.orders)
    forbidden_nodes = Set(_user_id(instance, id) for id in bundle.forbidden_nodes)
    forbidden_arcs = Set(
        (_user_id(instance, u), _user_id(instance, v)) for (u, v) in bundle.forbidden_arcs
    )
    return ArgumentError(
        "No feasible $label path for bundle $bundle_idx: " *
        "$(_user_id(instance, bundle.origin_id)) -> $(_user_id(instance, bundle.destination_id)), " *
        "max_transit_steps=$(max_steps), forbidden_nodes=$(forbidden_nodes), " *
        "forbidden_arcs=$(forbidden_arcs). " *
        "No elementary path from origin to destination: it may be blocked by the time budget, " *
        "the forbidden constraints or the arc and mode capacities" *
        (fixed_hint ? " (capacity may be taken by previously fixed direct bundles)" : ""),
    )
end

"""
$TYPEDSIGNATURES

Find the cheapest path for a bundle in the TravelTimeGraph and add it to the current
solution. Returns `false` without modifying `current_solution` if Dijkstra finds no
feasible path, `true` otherwise. When `snapshots` is given, the edges of the new path are
snapshotted into it before the insertion (see `_snapshot_path_assignments`).
"""
function _try_insert_bundle!(
    current_solution::SolutionState,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    snapshots::Union{Dict,Nothing}=nothing,
)
    ttg = instance.travel_time_graph
    update_bundle_cost_matrix!(
        current_solution, instance, bundle_idx, mode_selector; buffer=buffer
    )

    origin = ttg.origin_codes[bundle_idx]
    destination = ttg.destination_codes[bundle_idx]

    path = bundle_shortest_path(instance, origin, destination)

    isempty(path) && return false

    # Optionally snapshot the edges of the new path first, so the caller can roll back.
    if !isnothing(snapshots)
        _remove_shortcuts_from_path!(path, ttg)
        _snapshot_path_assignments(
            current_solution, instance, bundle_idx, path; cache=snapshots, clear=false
        )
    end
    add_bundle_path!(current_solution, instance, bundle_idx, path; mode_selector)
    return true
end

"""
$TYPEDSIGNATURES

Find the cheapest path for a bundle in the TravelTimeGraph and add it to the current
solution. Throws `ArgumentError` when no feasible path exists: see
[`_try_insert_bundle!`](@ref) for a non-throwing variant that returns `false` instead.
"""
function insert_bundle!(
    current_solution::SolutionState,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
)
    _try_insert_bundle!(current_solution, instance, bundle_idx, mode_selector; buffer) ||
        throw(_no_path_error(instance, bundle_idx, "insertion"))
    return nothing
end

"""
$TYPEDSIGNATURES

Construct a solution by inserting bundles one by one into an initially empty solution.
Bundles are processed in decreasing order of their largest single-commodity size,
so bundles with the hardest-to-pack items go first.
Each bundle is priced and committed by first-fit onto the existing bins of each arc,
except on `FillThenSpillMode` multimodal edges, which repack the modes they fill.

# Keyword arguments
- `mode_selector::AbstractModeSelector = CheapestMode()`: strategy that decides how
  a bundle's commodities are distributed across modes of a [`MultiModalArc`](@ref)
  (only relevant when several modes share the same transit time and therefore
  collapse to one edge). See [`CheapestMode`](@ref) and [`FillThenSpillMode`](@ref).
- `show_progress::Bool = true`: display a progress bar over the inserted bundles.

# Errors
Throws `ArgumentError` if no feasible path exists for a bundle. This can happen
when a required `NetworkArc` does not have enough remaining capacity, or, with
[`CheapestMode`](@ref), when no single mode on a required `MultiModalArc` edge
has enough remaining capacity. With [`FillThenSpillMode`](@ref), it happens when
the combined capacity across all modes on a required edge is below the load.
"""
function greedy_heuristic(
    instance::Instance;
    mode_selector::AbstractModeSelector=CheapestMode(),
    show_progress::Bool=true,
)
    solution = SolutionState(instance)
    # Sort bundles by decreasing max single-order pack size.
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    # One bin-packing scratch buffer reused across every bundle and arc.
    buffer = BinPackingBuffer()
    # Then, insert them one by one into the solution
    @showprogress enabled = show_progress for i in sorted_indices
        insert_bundle!(solution, instance, i, mode_selector; buffer)
    end
    return solution
end
