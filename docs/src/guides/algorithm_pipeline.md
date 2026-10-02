# [Algorithm Pipeline](@id algorithm_pipeline_guide)

TransportationPlanningOptimization.jl solves transportation planning problems in two phases: a **construction heuristic** builds an initial feasible solution, then **local search** improves it iteratively.

## Overview

The full pipeline looks like this:

```
lower_bound_filtering
        │
        ▼
extract_filtered_instance
        │
        ▼
preload_filtered_bundles     (reserve filtered bundles' capacity on the sub-instance)
        │
        ▼
mix_greedy_and_lower_bound   (on the sub-instance, seeded with the pre-load)
        │
        ▼
    local_search!            (on the sub-instance)
        │
        ▼
  merge_solutions            (stitch back onto full instance, checks feasibility)
```

The function [`solve`](@ref) runs this whole pipeline and is the recommended entry point.
The function [`solve_filtered`](@ref) wraps everything up to (but not including) local search, for workflows that need control over the local search step.

## Construction Heuristics

Three construction strategies are available.
All of them process bundles one at a time (sorted by largest order size), compute a cost matrix on the [`TravelTimeGraph`](@ref), run Dijkstra to find the cheapest path, and commit the bundle to that path.
Bundle paths must be elementary (they never revisit a physical node, though waiting on one is allowed).
Dijkstra runs first, and a label-setting search runs only when its path loops.

### Greedy heuristic

[`greedy_heuristic`](@ref) uses **incremental costs**: each bundle's cost matrix reflects the current state of the solution, so earlier placements influence later ones.
This produces good solutions but is order-dependent.

```julia
solution = greedy_heuristic(instance)
```

### Lower bound

[`lower_bound`](@ref) uses **relaxed costs**: each bundle's cost matrix is computed against the empty solution (independent of other bundles).
For [`BinPackingArcCost`](@ref) arcs, this means fractional bin counts instead of integer ones.
The result is a cost lower bound (when costs are linear in volume) that can be used to estimate solution quality.

```julia
lb_solution = lower_bound(instance)
```

### Mixed start

[`mix_greedy_heuristic`](@ref) is the convenience wrapper: it builds three candidate solutions internally and returns the cheapest feasible one.

```julia
solution = mix_greedy_heuristic(instance)
```

Under the hood, [`mix_greedy_and_lower_bound`](@ref TransportationPlanningOptimization.mix_greedy_and_lower_bound) builds three solutions simultaneously in a single pass: pure greedy, pure lower bound, and a **blended** solution whose cost matrix interpolates between greedy and lower-bound costs.
The blend weight shifts toward greedy as more bundles are placed.
Then [`choose_best_feasible`](@ref TransportationPlanningOptimization.choose_best_feasible) picks the cheapest feasible candidate.

## Filtering Pipeline

On large instances, many bundles have only one reasonable path (the direct arc from origin to destination).
The filtering pipeline pre-routes those trivial bundles so the heavier algorithms work on a smaller sub-instance.

1. [`lower_bound_filtering`](@ref) routes every bundle using a hybrid cost that favors direct arcs.
   Bundles whose resulting path has exactly two nodes (origin -> destination) are considered "trivial".
2. [`extract_filtered_instance`](@ref TransportationPlanningOptimization.extract_filtered_instance) builds a sub-instance containing only the non-trivial bundles.
3. [`preload_filtered_bundles`](@ref TransportationPlanningOptimization.preload_filtered_bundles) builds a `start` solution on the sub-instance that reserves the capacity and cost already claimed by the filtered-out bundles on arcs the sub-instance still contains.
   This is required because a filtered-out bundle can share an arc with a kept bundle, and the construction heuristic must not oversubscribe that arc.
4. The construction heuristic runs on the sub-instance, seeded with that `start` solution.
5. [`merge_solutions`](@ref TransportationPlanningOptimization.merge_solutions) stitches the sub-instance solution back onto the full-instance filtering solution.
   It always checks `is_feasible` on the merged result and throws `ArgumentError` if it fails.

[`solve_filtered`](@ref) wraps steps 1-4:

```julia
result = solve_filtered(instance)
# result.solution lives on result.sub_instance
# result.filtering_solution is the full-instance solution of step 1
```

`cost(result.solution)` already includes the reserved load of filtered
bundles whose direct arc is still in `result.sub_instance`, so it is neither
the sub-instance cost nor the full-instance cost.
The full-instance cost is `cost(merge_solutions(result.filtering_solution, result.solution, instance, result.sub_instance))`.

## Local Search

[`local_search!`](@ref) improves a solution in place using random-neighborhood search.
Each iteration randomly picks one of two moves:

- **Bundle reintroduction**: remove a random bundle's path, recompute costs, find a new path via Dijkstra (with the elementary fallback), accept if the total cost strictly improves.
- **Two-node consolidation**: pick a random arc `(src, dst)` in the travel-time graph, lift all bundles passing through it, reroute the shared segment via Dijkstra (with the elementary fallback), accept if cost improves.

The loop stops when any of three conditions is met: `time_limit` seconds elapsed, `max_iter` iterations reached, or `max_no_improv` consecutive iterations without improvement.

A final [`bin_packing_improvement!`](@ref TransportationPlanningOptimization.bin_packing_improvement!) pass runs at the end when `allow_repack=true` (the default).

```julia
stats = local_search!(solution, instance; time_limit=60.0)
# stats.saved, stats.final_cost, stats.n_iter
```

## Putting It All Together

### Recommended: `solve`

[`solve`](@ref) runs the filtering pipeline, local search on the sub-instance, and the merge:

```julia
solution = solve(instance; time_limit=120.0)
is_feasible(solution, instance; verbose=true)
println("Cost: ", cost(solution))
```

Running [`greedy_heuristic`](@ref) on the full instance is much slower on large instances, because its cost scales with the number of unit commodities times the number of bundle arcs.
On a very large instance the difference is hours against a couple of minutes.
`time_limit` only covers local search, and `solve` uses [`CheapestMode`](@ref) for every step.

For small instances you can skip filtering with `filtering=false`, which runs construction and local search on the full instance:

```julia
solution = solve(instance; filtering=false)
```

### Manual pipeline with filtering

Use the building blocks when you need another local search, such as [`iterated_local_search!`](@ref), on the sub-instance:

```julia
# Filter, build the sub-instance, pre-load, construct the initial solution
result = solve_filtered(instance)

# Improve the sub-instance solution (or use iterated_local_search!)
stats = local_search!(result.solution, result.sub_instance; time_limit=300.0)

# Stitch back onto the full instance
final_solution = merge_solutions(
    result.filtering_solution, result.solution, instance, result.sub_instance
)

is_feasible(final_solution, instance; verbose=true)
println("Cost: ", cost(final_solution))
```

## Keyword Options

### Mode selectors

When arcs carry a [`MultiModalArc`](@ref) (multiple transport modes on the same edge), a mode selector controls how commodities are distributed across modes:

- [`CheapestMode()`](@ref) (default): place everything on the single cheapest mode that has enough capacity.
- [`FillThenSpillMode()`](@ref): fill the cheapest mode to capacity, spill overflow to the next cheapest.

Pass via the `mode_selector` keyword (the function [`solve`](@ref) always uses `CheapestMode()`):

```julia
solution = greedy_heuristic(instance; mode_selector=FillThenSpillMode())
```

### Packing semantics

For [`BinPackingArcCost`](@ref) arcs, the `packing` keyword controls how commodities are packed into bins:

- `:frozen` (default for greedy): cache committed bins and pack only new commodities onto remaining capacity (faster).
- `:ffd_union` (default for local search): re-pack the union of existing and new commodities from scratch on every evaluation (slightly better packing).

```julia
solution = greedy_heuristic(instance; packing=:ffd_union)
stats = local_search!(solution, instance; packing=:ffd_union, cost_packing=:frozen)
```
