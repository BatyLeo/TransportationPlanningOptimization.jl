# [Solution I/O](@id solution_io_guide)

## [Reading a solution on the input network](@id solution_guide)

[`Solution`](@ref) is what [`solve`](@ref) returns: the plan expressed on your own input, the arcs and commodities you gave to the [`Instance`](@ref), by their position in the input vectors.
It holds two vectors of plain structs, `Leg` and `ArcFlow`, with the fields listed below.
For a [`SolutionState`](@ref) coming from a building block such as [`greedy_heuristic`](@ref), build a `Solution` with `Solution(solution_state, instance)`.

```julia
solution = solve(instance)
solution.routes[k]   # legs of the k-th input commodity, in travel order
solution.arc_flows   # load per input arc and departure date
```

- Each leg of `routes[k]` is a `Leg` with fields `(arc, departure, arrival, quantity)`, where `arc` is the index of the input arc.
  The `quantity` copies of a commodity share one route, but a leg only counts the copies using that input arc, since a multi-modal edge can split them across modes.
- Each row of `arc_flows` is an `ArcFlow` with fields `(arc, departure, arrival, volume, n_bins, arc_cost, node_cost)`, sorted by `(arc, departure)`.
  The sum of `arc_cost + node_cost` over the rows is `cost(solution)`, which equals the cost of the state it was built from (up to floating point summation order).
  The node cost of a multi-modal edge is charged once, on its first non-empty mode row.

To check an edited plan, call `is_feasible(solution, instance)`, which rebuilds the plan from the routes and ignores `arc_flows`.
To continue improving it, call `solve(instance; start=solution)` (see [Working with SolutionState (advanced)](@ref solution_state_guide)).

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

## [Building a SolutionState from a Solution](@id solution_state_from_solution)

A plan written on the input network, such as a [`Solution`](@ref) edited by hand or produced by another tool, can be turned back into a [`SolutionState`](@ref).

```julia
solution_state = SolutionState(solution, instance)
is_feasible(solution_state, instance; verbose=true)
```

- The routes are the source of truth and the input arcs they use (modes) are kept, while `arc_flows` is ignored.
- Every slot is repacked from scratch by first-fit decreasing, so bins and costs only match the original state for linear costs (up to floating point summation order).
- Capacity is not checked, so call [`is_feasible`](@ref) on the result.
- Several legs on the same arc at the same position (same departure and arrival) are merged.
- Plans that cannot be represented throw an `ArgumentError` naming the commodity (and the leg when relevant), such as partial routes, commodities larger than the bin capacity of their arc, off-grid dates, waiting anywhere but before the first leg (arrival dates) or after the last leg (departure dates), legs that overlap, routes longer than the maximum delivery time of their commodity group, routes that leave the time horizon when `wrap_time` is off or pass through an origin or destination node that routes cannot cross at that date, and commodities with the same origin, destination and group key that do not follow the same path (same nodes and transit times) at the same offsets from their order date.
- A route is pinned to the order date: its arrival (arrival-date mode) or its departure (departure-date mode) must equal the order date.
- The solution-level round trip `Solution(SolutionState(solution, instance), instance) == solution` only holds for solutions produced by `Solution(solution_state, instance)`.
  Other plans come back normalized, with the legs of one leg position merged and in slot order and identical copies attributed by count.
- Commodities dropped by an extraction must have an empty route, and the load reserved for them is not rebuilt.

To get a full [`Solution`](@ref) back from edited routes, with `arc_flows` and cost rebuilt, use `Solution(routes, instance)`.
It validates the routes like `SolutionState(solution, instance)` does, then converts the state back.

```julia
solution = Solution(edited_routes, instance)
cost(solution)
```

## CSV files

The routes of a [`Solution`](@ref) can be saved to and loaded from a CSV file with [`write_solution_csv`](@ref) and [`read_solution_csv`](@ref).

## Writing a solution

```julia
write_solution_csv("solution.csv", solution)
```

The file has one row per leg, with columns:

| Column | Description |
|--------|-------------|
| `commodity` | index of the input commodity |
| `leg` | 1-based position of the leg in the route of the commodity |
| `arc` | index of the input arc |
| `departure` | departure date of the leg |
| `arrival` | arrival date of the leg |
| `quantity` | number of copies carried on the leg |

Commodities with an empty route have no rows, and the file holds the routes only, not `arc_flows`.
To export the flows too, use `CSV.write("flows.csv", solution.arc_flows)`.

## Reading a solution

```julia
solution = read_solution_csv("solution.csv", instance)
```

The reader gets the routes from the file and returns `Solution(routes, instance)`, so the plan is validated like in [`SolutionState(solution, instance)`](@ref solution_state_from_solution) and its `arc_flows` and cost are rebuilt.
Bins are repacked, so the cost only equals the original one for linear costs.
Rows can come in any order, since legs are placed by their `leg` number, and commodities without rows get an empty route.

A missing column throws an `ArgumentError` naming it.
An `ArgumentError` with the row number (the non-empty rows after the header are counted, the first being row 1) is thrown for a missing or unparsable value, a commodity outside the input commodities, or leg numbers of a commodity that are not exactly `1:n` (duplicates or gaps).
A file whose routes are not a valid plan on the instance is rejected by `Solution(routes, instance)` with an `ArgumentError`.
Capacity is not checked, so call [`is_feasible`](@ref) on the result.
Extra fields in a row are ignored with a CSV warning.

## Round-trip example

```julia
using TransportationPlanningOptimization
using Dates

# Build instance and solve
instance = Instance(nodes, arcs, commodities, Day(1))
solution = solve(instance)

# Save
write_solution_csv("my_solution.csv", solution)

# Load back
reloaded = read_solution_csv("my_solution.csv", instance)

# Verify
println("Same routes:    ", reloaded.routes == solution.routes)
println("Original cost:  ", cost(solution))
println("Reloaded cost:  ", cost(reloaded))
println("Feasible:       ", is_feasible(reloaded, instance))
```
