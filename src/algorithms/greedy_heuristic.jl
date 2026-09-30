"""
$TYPEDSIGNATURES

Find the cheapest path for a bundle in the TravelTimeGraph and add it to the current
solution. Returns `false` without modifying `current_solution` if Dijkstra finds no
feasible path, `true` otherwise.
"""
function _try_insert_bundle!(
    current_solution::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
)
    ttg = instance.travel_time_graph
    update_bundle_cost_matrix!(
        current_solution,
        instance,
        bundle_idx,
        mode_selector;
        buffer=buffer,
        packing=packing,
    )

    origin = ttg.origin_codes[bundle_idx]
    destination = ttg.destination_codes[bundle_idx]

    parents, _ = bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=destination)
    path = trace_path(parents, origin, destination)

    isempty(path) && return false

    add_bundle_path!(current_solution, instance, bundle_idx, path; mode_selector, packing)
    return true
end

"""
$TYPEDSIGNATURES

Find the cheapest path for a bundle in the TravelTimeGraph and add it to the current
solution. Throws `ArgumentError` when no feasible path exists: see
[`_try_insert_bundle!`](@ref) for a non-throwing variant that returns `false` instead.
"""
function insert_bundle!(
    current_solution::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    buffer::BinPackingBuffer=BinPackingBuffer(),
    packing::Symbol=:frozen,
)
    _try_insert_bundle!(
        current_solution, instance, bundle_idx, mode_selector; buffer, packing
    ) || throw(ArgumentError("No feasible path found for bundle $bundle_idx"))
    return nothing
end

"""
$TYPEDSIGNATURES

Construct a solution by inserting bundles one by one into an initially empty solution.
Bundles are processed in decreasing order of their largest single-commodity size,
so bundles with the hardest-to-pack items go first.

# Keyword arguments
- `mode_selector::AbstractModeSelector = CheapestMode()`: strategy that decides how
  a bundle's commodities are distributed across modes of a [`MultiModalArc`](@ref)
  (only relevant when several modes share the same transit time and therefore
  collapse to one edge). See [`CheapestMode`](@ref) and [`FillThenSpillMode`](@ref).
- `packing::Symbol = :frozen`: bin-packing semantics on `BinPackingArcCost`
  arcs. The default `:frozen` caches the committed bins per arc and packs only
  the new commodities onto the existing bins' remaining capacities via first-fit,
  opening new bins as needed. The opt-in `:ffd_union` re-packs the
  union of existing and new commodities from scratch (First-Fit Decreasing) on
  every cost evaluation and commit. `:frozen` is cheaper (no union re-pack) and
  gives bin counts within a fraction of a percent of `:ffd_union`. Both the cost
  matrix and the committed solution use the same semantics, so predicted and
  committed costs agree.
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
    packing::Symbol=:frozen,
    show_progress::Bool=true,
)
    solution = Solution(instance)
    # Sort bundles by decreasing max single-order pack size.
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    # One bin-packing scratch buffer reused across every bundle and arc.
    buffer = BinPackingBuffer()
    # Then, insert them one by one into the solution
    @showprogress enabled = show_progress for i in sorted_indices
        insert_bundle!(solution, instance, i, mode_selector; buffer=buffer, packing=packing)
    end
    return solution
end
