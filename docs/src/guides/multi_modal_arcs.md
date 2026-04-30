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

During `greedy_heuristic`, the insertion cost for a multi-modal edge is `minimum(incremental_cost(mode) for mode in modes)`. After Dijkstra selects the path, `add_bundle_path!` assigns commodities to the mode with the lowest incremental cost at that moment.

```julia
sol = greedy_heuristic(instance)
cost(sol)  # 3 units × 5.0/unit = 15.0 (train chosen)
```

Inspect the per-mode breakdown via the `MultiAssignment` stored in `sol.assignments`:

```julia
assignment = only(values(sol.assignments))
# assignment isa MultiAssignment

for (i, slot) in enumerate(assignment.per_mode)
    println("mode $i: $(length(commodities_of(slot))) commodities, cost $(cost_of(slot))")
end
```

## Per-Mode Capacity

Each mode's `capacity` field is checked independently by `is_feasible`. Because the greedy rule always picks the cheapest mode, it is possible to overflow one mode's capacity while the other remains empty. This is by design: the greedy solver is mode-greedy, not load-balancing. If feasibility matters, either raise the cheap mode's capacity or add a post-processing rebalancing step.

```julia
arc_tight = Arc(; origin_id="A", destination_id="B",
                   cost=LinearArcCost(5.0), travel_time=Day(1), capacity=1)
arc_loose = Arc(; origin_id="A", destination_id="B",
                   cost=LinearArcCost(10.0), travel_time=Day(1), capacity=100)
# If 3 units arrive and the cheap mode has capacity 1, greedy fills it to 3 → infeasible
```

## See Also

- [Cost functions](@ref) for `LinearArcCost` and `BinPackingArcCost` details.
- A future capacity-shape guide will cover step-bin-packing and min/max capacity constraints.
