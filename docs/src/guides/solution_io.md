# [Solution I/O](@id solution_io_guide)

## [Reading a solution on the input network](@id solution_guide)

[`Solution`](@ref) expresses a [`SolutionState`](@ref) on your own input: the arcs and commodities you gave to the [`Instance`](@ref), by their position in the input vectors.
It is built on demand and holds two vectors of plain structs, `Leg` and `ArcFlow`, with the fields listed below.

```julia
solution = Solution(solution_state, instance)
solution.routes[k]   # legs of the k-th input commodity, in travel order
solution.arc_flows   # load per input arc and departure date
```

- Each leg of `routes[k]` is a `Leg` with fields `(arc, departure, arrival, quantity)`, where `arc` is the index of the input arc.
  The `quantity` copies of a commodity share one route, but a leg only counts the copies using that input arc, since a multi-modal edge can split them across modes.
- Each row of `arc_flows` is an `ArcFlow` with fields `(arc, departure, arrival, volume, n_bins, arc_cost, node_cost)`, sorted by `(arc, departure)`.
  The sum of `arc_cost + node_cost` over the rows is `cost(solution_state)`.
  The node cost of a multi-modal edge is charged once, on its first non-empty mode row.

Date conventions:

- Dates are the start of a time step, since order dates and transit times are floored to the time step.
  The arrival of a leg is its departure plus the floored transit time.
- Waiting is implicit: it is the gap before the first leg (arrival dates) or after the last leg (departure dates).
- Route dates are unwrapped, computed from the order date and the travel-time budget, so with `wrap_time` they can leave the horizon.
- With `wrap_time`, the departure of an `arc_flows` row is cyclic and its arrival is the departure plus the transit time, so it can pass the end of the horizon.
  To join a leg to its row, compare the cyclic step of the departures, `mod(fld(departure - instance.time_step_to_date[1], instance.time_step), instance.time_horizon_length) + 1` (for fixed-length time steps).
- Copies with equal size and info cannot be told apart, so when an order is split across modes they are attributed to modes by count.
  This also holds for equal copies of other orders, other bundles or reservation commodities on the same edge (possible only with a custom `group_by` splitting on something outside `info`).
  Totals stay consistent and only the mode of such a leg is arbitrary.
- Commodities dropped by [`TransportationPlanningOptimization.extract_filtered_instance`](@ref) have an empty route, and the load reserved for them only appears in `arc_flows`.

To flatten the routes into a table with a `commodity` column:

```julia
using DataFrames
routes = DataFrame([
    (; commodity=k, leg.arc, leg.departure, leg.arrival, leg.quantity) for
    (k, route_legs) in enumerate(solution.routes) for leg in route_legs
])
flows = DataFrame(solution.arc_flows)
```

## CSV files

Solutions can be saved to and loaded from CSV files using [`write_solution_csv`](@ref) and [`read_solution_csv`](@ref).

## Writing a solution

```julia
write_solution_csv("solution.csv", solution_state, instance)
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
solution_state = read_solution_csv("solution.csv", instance)
```

The reader reconstructs full time-expanded paths from the spatial node sequence using BFS in the [`TravelTimeGraph`](@ref).
It validates that all node IDs and bundle indices exist in the instance.

For instances with [`MultiModalArc`](@ref) edges, pass a `mode_selector` to control how commodities are distributed across modes during reconstruction:

```julia
solution_state = read_solution_csv("solution.csv", instance; mode_selector=FillThenSpillMode())
```

The default is [`CheapestMode()`](@ref).

## Round-trip example

```julia
using TransportationPlanningOptimization
using Dates

# Build instance and solve
instance = Instance(nodes, arcs, commodities, Day(1))
solution_state = solve(instance)

# Save
write_solution_csv("my_solution.csv", solution_state, instance)

# Load back
reloaded = read_solution_csv("my_solution.csv", instance)

# Verify
println("Original cost:  ", cost(solution_state))
println("Reloaded cost:  ", cost(reloaded))
println("Feasible:       ", is_feasible(reloaded, instance))
```
