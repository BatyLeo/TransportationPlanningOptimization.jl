# Multi-Modal Arcs

A multi-modal arc models a physical leg (a pair of locations) that can be served by more than one transport mode, such as road and rail. Each mode may have a different transit time, cost structure, and capacity.

## Case 1 vs Case 2

**Case 1 — distinct transit times.** Modes land at different timed vertices in the time-expanded graphs, so each mode becomes its own edge in the `TimeSpaceGraph` and `TravelTimeGraph`. No special handling is required in the solution layer.

**Case 2 — same transit time.** Both modes arrive at the same `(node, t)` vertex. The time-expanded graphs collapse them into a single `MultiModalArc` edge. The greedy heuristic then picks the cheapest mode per bundle insertion.

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

The `greedy_heuristic` accepts a `mode_selection` keyword that controls how commodities are distributed across modes on a multi-modal edge. Two strategies are available:

- **`:cheapest`** (default): all commodities go to the single cheapest mode. Fast and simple, but can overflow a mode's capacity while others remain empty.
- **`:fill_then_spill`**: fill the cheapest mode up to its capacity, then spill overflow to the next-cheapest mode, and so on. Produces feasible solutions when capacity constraints are tight.

```julia
sol = greedy_heuristic(instance)                                    # :cheapest (default)
sol = greedy_heuristic(instance; mode_selection=:fill_then_spill)   # capacity-aware
cost(sol)
```

Inspect the per-mode breakdown via the `MultiAssignment` stored in `sol.assignments`:

```julia
assignment = only(values(sol.assignments))
# assignment isa MultiAssignment

for (i, slot) in enumerate(assignment.per_mode)
    println("mode $i: $(length(commodities_of(slot))) commodities, cost $(cost_of(slot))")
end
```

!!! note
    `:fill_then_spill` currently applies to case 2 only (modes with the same transit time that share a `MultiModalArc` edge). For case 1 (distinct transit times), Dijkstra naturally routes bundles to the cheapest available mode, so capacity-aware splitting across modes with different transit times is a planned future extension.

## Per-Mode Capacity

Each mode's `capacity` field is checked independently by `is_feasible`. With the default `:cheapest` strategy, it is possible to overflow one mode's capacity while the other remains empty. Use `:fill_then_spill` to distribute commodities across modes respecting per-mode capacity.

```julia
arc_tight = Arc(; origin_id="A", destination_id="B",
                   cost=LinearArcCost(5.0), travel_time=Day(1), capacity=1)
arc_loose = Arc(; origin_id="A", destination_id="B",
                   cost=LinearArcCost(10.0), travel_time=Day(1), capacity=100)

# With :cheapest, 3 units all go to the cheap mode → infeasible (capacity=1)
# With :fill_then_spill, 1 unit fills cheap mode, 2 spill to expensive mode → feasible
```

## See Also

- [Cost functions](@ref cost_functions_guide) for `LinearArcCost` and `BinPackingArcCost` details.
- A future capacity-shape guide will cover step-bin-packing and min/max capacity constraints.
