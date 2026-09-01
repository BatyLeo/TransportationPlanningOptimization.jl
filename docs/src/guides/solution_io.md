# [Solution I/O](@id solution_io_guide)

Solutions can be saved to and loaded from CSV files using [`write_solution_csv`](@ref) and [`read_solution_csv`](@ref).

## Writing a solution

```julia
write_solution_csv("solution.csv", solution, instance)
```

The CSV contains one row per node in each bundle's path, with columns:

| Column | Description |
|--------|-------------|
| `bundle_idx` | 1-based bundle index |
| `origin_id` | bundle origin node ID |
| `destination_id` | bundle destination node ID |
| `node_id` | spatial node ID at this path point |
| `point_number` | position in the path (1 = destination, last = origin) |
| `point_type` | `:destination`, `:other`, or `:origin` |

Paths are written in **reverse order** (destination to origin).

## Reading a solution

```julia
solution = read_solution_csv("solution.csv", instance)
```

The reader reconstructs full time-expanded paths from the spatial node sequence using BFS in the [`TravelTimeGraph`](@ref).
It validates that all node IDs and bundle indices exist in the instance.

For instances with [`MultiModalArc`](@ref) edges, pass a `mode_selector` to control how commodities are distributed across modes during reconstruction:

```julia
solution = read_solution_csv("solution.csv", instance; mode_selector=FillThenSpillMode())
```

The default is [`CheapestMode()`](@ref).

## Round-trip example

```julia
using TransportationPlanningOptimization
using Dates

# Build instance and solve
instance = Instance(nodes, arcs, commodities, Day(1))
solution = greedy_heuristic(instance)

# Save
write_solution_csv("my_solution.csv", solution, instance)

# Load back
reloaded = read_solution_csv("my_solution.csv", instance)

# Verify
println("Original cost:  ", cost(solution))
println("Reloaded cost:  ", cost(reloaded))
println("Feasible:       ", is_feasible(reloaded, instance))
```
