"""
$TYPEDSIGNATURES

Find the cheapest path for a bundle in the TravelTimeGraph and add it to the current solution.
"""
function insert_bundle!(
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

    if isempty(path)
        throw(ArgumentError("No feasible path found for bundle $bundle_idx, ($path)"))
    end

    add_bundle_path!(current_solution, instance, bundle_idx, path; mode_selector, packing)
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

# Errors
Throws `ArgumentError` if no feasible path exists for a bundle. With
[`CheapestMode`](@ref), this can happen when no single mode on a required edge
has enough remaining capacity. With [`FillThenSpillMode`](@ref), it happens when
the combined capacity across all modes on a required edge is below the load.
"""
function greedy_heuristic(
    instance::Instance;
    mode_selector::AbstractModeSelector=CheapestMode(),
    packing::Symbol=:frozen,
)
    solution = Solution(instance)
    # Sort bundles by decreasing max single-order pack size.
    sorted_indices = sortperm(instance.bundles; by=max_pack_size, rev=true)
    # One bin-packing scratch buffer reused across every bundle and arc.
    buffer = BinPackingBuffer()
    # Then, insert them one by one into the solution
    @showprogress for i in sorted_indices
        insert_bundle!(solution, instance, i, mode_selector; buffer=buffer, packing=packing)
    end
    return solution
end
