# Multi-Modal Arcs

A multi-modal arc models a physical leg (a pair of locations) that can be served by more than one transport mode, such as road and rail. Each mode may have a different transit time, cost structure, and capacity.

## Case 1 vs Case 2

**Case 1 (distinct transit times).** Modes land at different timed vertices in the time-expanded graphs, so each mode becomes its own edge in the `TimeSpaceGraph` and `TravelTimeGraph`. No special handling is required in the solution layer.

**Case 2 (same transit time).** Both modes arrive at the same `(node, t)` vertex. The time-expanded graphs collapse them into a single `MultiModalArc` edge. The greedy heuristic then picks the cheapest mode with sufficient remaining capacity per bundle insertion.

## Declaring Multi-Modal Arcs

Pass two (or more) `Arc` objects with the same `(origin_id, destination_id)` and the same `travel_time` to `Instance`. The `NetworkGraph` promotes the repeated leg to a `MultiModalArc` automatically.

```julia
using TransportationPlanningOptimization
using Dates

nodes = [
    NetworkNode(; id="A", node_type=:origin),
    NetworkNode(; id="B", node_type=:destination),
]

arcs = [
    Arc(; origin_id="A", destination_id="B", cost=LinearArcCost(10.0), travel_time=Day(1)),  # truck
    Arc(; origin_id="A", destination_id="B", cost=LinearArcCost(5.0),  travel_time=Day(1)),  # train
]

commodities = [
    Commodity(;
        origin_id="A", destination_id="B",
        quantity=3,
        departure_date=DateTime(2024, 1, 1),
        max_delivery_time=Day(1),
        size=1.0,
    ),
]

instance = Instance(nodes, arcs, commodities, Day(1))
```

For case 1, use different `travel_time` values (e.g. `Day(1)` for truck and `Day(2)` for rail). Each mode then occupies its own time-expanded edge with zero overhead compared to a single-mode network.

## Cost Evaluation and Mode Selection

The `greedy_heuristic` accepts a `mode_selector` keyword that controls how commodities are distributed across modes on a multi-modal edge. Two strategies are available, both subtypes of [`AbstractModeSelector`](@ref):

- [`CheapestMode`](@ref) (default): each bundle's order is placed entirely on the cheapest mode whose remaining capacity can absorb it. Modes that would overflow are skipped. If no mode on an edge has enough capacity, the edge is treated as infeasible (Inf cost) and Dijkstra routes around it. If no feasible path exists, `greedy_heuristic` throws `ArgumentError`.
- [`FillThenSpillMode`](@ref): fill the cheapest mode up to its capacity, then spill overflow to the next-cheapest mode on the same edge, and so on. Unlike `CheapestMode`, this can split a single order's commodities across modes that share the same transit time. If the combined capacity across all modes on an edge is below the load, the edge is also treated as infeasible.

```julia
sol = greedy_heuristic(instance)                                          # CheapestMode (default)
sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode())       # capacity-aware
cost(sol)
```

Inspect the per-mode breakdown via the `MultiAssignment` stored in `sol.assignments`:

```julia
assignment = only(values(sol.assignments))
# assignment isa MultiAssignment

for (i, slot) in enumerate(assignment.per_mode)
    println("mode $i: $(length(slot.commodities)) commodities, cost $(cost_of(slot))")
end
```

!!! note
    `FillThenSpillMode` only splits a bundle across modes that share the same transit time (and therefore the same `MultiModalArc` edge in the time-expanded graphs). Splitting across modes with different transit times is intentionally disallowed. The two modes occupy separate edges with independent per-edge capacities, and mixing would create an inconsistent capacity accounting. When transit times differ, mode selection still happens at the bundle level via Dijkstra: as the cheaper mode's incremental cost rises with utilization, later bundles route via the other mode.

## Per-Mode Capacity

Each mode's `capacity` field is checked independently by `is_feasible`, and both selectors respect it during insertion. The two strategies differ in how they react to a too-small mode.

```julia
arc_tight = Arc(; origin_id="A", destination_id="B",
                   cost=LinearArcCost(5.0), travel_time=Day(1), capacity=1)
arc_loose = Arc(; origin_id="A", destination_id="B",
                   cost=LinearArcCost(10.0), travel_time=Day(1), capacity=100)

# With CheapestMode, 3 units cannot fit the cheap mode (capacity=1),
#   so the whole order goes to the expensive mode -> cost = 3 * 10 = 30.0
# With FillThenSpillMode, 1 unit fills the cheap mode and 2 spill to the
#   expensive mode -> cost = 1 * 5 + 2 * 10 = 25.0
```

`FillThenSpillMode` can therefore produce strictly cheaper solutions whenever an order is larger than the cheapest mode but smaller than the combined capacity on a single edge. `CheapestMode` is preferable when you want to keep each order intact on a single mode (e.g. for traceability or to avoid mid-leg transfers).

If *no* mode on an edge has enough capacity for an order, `CheapestMode` cannot place that order at all and `greedy_heuristic` throws `ArgumentError`. Switch to `FillThenSpillMode` (which can distribute the order across multiple modes on the same edge) or relax the input capacities. If even the combined capacity of every mode on an edge is below the load, `FillThenSpillMode` also throws `ArgumentError`.

## See Also

- [Cost functions](@ref cost_functions_guide) for `LinearArcCost` and `BinPackingArcCost` details.
