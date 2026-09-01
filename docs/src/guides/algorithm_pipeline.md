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
mix_greedy_and_lower_bound   (on the sub-instance)
        │
        ▼
    local_search!            (on the sub-instance)
        │
        ▼
  merge_solutions            (stitch back onto full instance)
```

The function [`solve_filtered`](@ref) wraps the first three steps.
For simple cases you can skip filtering entirely and use [`greedy_heuristic`](@ref) directly.

## Construction Heuristics

Three construction strategies are available.
All of them process bundles one at a time (sorted by largest order size), compute a cost matrix on the [`TravelTimeGraph`](@ref), run Dijkstra to find the cheapest path, and commit the bundle to that path.

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
3. The construction heuristic runs on the sub-instance.
4. [`merge_solutions`](@ref TransportationPlanningOptimization.merge_solutions) stitches the sub-instance solution back onto the full-instance filtering solution.

[`solve_filtered`](@ref) wraps steps 1-3:

```julia
result = solve_filtered(instance)
# result.solution lives on result.sub_instance
```

## Local Search

[`local_search!`](@ref) improves a solution in place using random-neighborhood search.
Each iteration randomly picks one of two moves:

- **Bundle reintroduction**: remove a random bundle's path, recompute costs, find a new path via Dijkstra, accept if the total cost strictly improves.
- **Two-node consolidation**: pick a random arc `(src, dst)` in the travel-time graph, lift all bundles passing through it, reroute the shared segment via Dijkstra, accept if cost improves.

The loop stops when any of three conditions is met: `time_limit` seconds elapsed, `max_iter` iterations reached, or `max_no_improv` consecutive iterations without improvement.

A final [`bin_packing_improvement!`](@ref TransportationPlanningOptimization.bin_packing_improvement!) pass runs at the end when `allow_repack=true` (the default).

```julia
stats = local_search!(solution, instance; time_limit=60.0)
# stats.saved, stats.final_cost, stats.n_iter
```

## Putting It All Together

### Simple path

For quick experiments, the greedy heuristic followed by local search is enough:

```julia
solution = greedy_heuristic(instance)
stats = local_search!(solution, instance; time_limit=120.0)
is_feasible(solution, instance; verbose=true)
println("Cost: ", cost(solution))
```

### Full pipeline with filtering

For large instances, use the filtering pipeline:

```julia
# Steps 1-3: filter, build sub-instance, construct initial solution
result = solve_filtered(instance)

# Step 4: local search on the sub-instance
stats = local_search!(result.solution, result.sub_instance; time_limit=300.0)

# Step 5: stitch back onto the full instance
filtering_sol = lower_bound_filtering(instance)
final_solution = merge_solutions(filtering_sol, result.solution, instance, result.sub_instance)

is_feasible(final_solution, instance; verbose=true)
println("Cost: ", cost(final_solution))
```

## Keyword Options

### Mode selectors

When arcs carry a [`MultiModalArc`](@ref) (multiple transport modes on the same edge), a mode selector controls how commodities are distributed across modes:

- [`CheapestMode()`](@ref) (default): place everything on the single cheapest mode that has enough capacity.
- [`FillThenSpillMode()`](@ref): fill the cheapest mode to capacity, spill overflow to the next cheapest.

Pass via the `mode_selector` keyword:

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
