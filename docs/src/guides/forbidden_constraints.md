# [Forbidden Constraints](@id forbidden_constraints_guide)

TransportationPlanningOptimization.jl allows you to specify routing restrictions for commodities using **forbidden constraints**. These constraints prevent commodities from using certain nodes or arcs in their routes.

## Types of Forbidden Constraints

### Forbidden Nodes

Prevent commodities from passing through specific intermediate nodes.

```julia
Commodity(;
    origin_id="A",
    destination_id="D",
    arrival_date=DateTime(2025, 1, 5),
    max_delivery_time=Day(3),
    size=100.0,
    forbidden_node_ids=["B", "C"]  # Cannot pass through nodes B or C
)
```

**Important:** You cannot forbid the origin or destination nodes of a commodity. Attempting to do so will raise an `ArgumentError`.

### Forbidden Arcs

Prevent commodities from using specific transportation links.

```julia
Commodity(;
    origin_id="A",
    destination_id="D",
    arrival_date=DateTime(2025, 1, 5),
    max_delivery_time=Day(3),
    size=100.0,
    forbidden_arcs=[("A", "B"), ("C", "D")]  # Cannot use these specific arcs
)
```

Each forbidden arc is specified as a tuple `(origin_id, destination_id)`.

### Combining Both Types

You can use both forbidden nodes and forbidden arcs on the same commodity:

```julia
Commodity(;
    origin_id="A",
    destination_id="D",
    arrival_date=DateTime(2025, 1, 5),
    max_delivery_time=Day(3),
    size=100.0,
    forbidden_node_ids=["B"],           # Avoid node B
    forbidden_arcs=[("C", "D")]         # Also avoid the C→D arc
)
```

## Complete Example

Let's create a diamond network with routing restrictions:

```julia
using TransportationPlanningOptimization
using Dates

# Network topology:
#    ┌→ B →┐
#  A ┤     ├→ D
#    └→ C →┘

nodes = [
    NetworkNode(; id="A", node_type=:origin),
    NetworkNode(; id="B", node_type=:other),
    NetworkNode(; id="C", node_type=:other),
    NetworkNode(; id="D", node_type=:destination),
]

arcs = [
    # Two paths: A→B→D and A→C→D
    Arc(; origin_id="A", destination_id="B", 
         cost=LinearArcCost(5.0), travel_time=Day(1)),
    Arc(; origin_id="A", destination_id="C", 
         cost=LinearArcCost(3.0), travel_time=Day(1)),
    Arc(; origin_id="B", destination_id="D", 
         cost=LinearArcCost(5.0), travel_time=Day(1)),
    Arc(; origin_id="C", destination_id="D", 
         cost=LinearArcCost(3.0), travel_time=Day(1)),
]

# Commodity that must avoid node B (forcing it to use the A→C→D path)
commodity_avoid_b = Commodity(;
    origin_id="A",
    destination_id="D",
    arrival_date=DateTime(2025, 1, 3),
    max_delivery_time=Day(2),
    size=10.0,
    forbidden_node_ids=["B"]
)

instance = Instance(nodes, arcs, [commodity_avoid_b], Day(1))
solution = greedy_heuristic(instance)

# The solution will route through C, not B
println("Cost: ", cost(solution))  # Will use cheaper A→C→D path
```

## Behavior with Bundles

When multiple commodities are aggregated into bundles, their forbidden constraints are **unioned**:

```julia
# Two commodities going from A to D
commodities = [
    Commodity(;
        origin_id="A", destination_id="D",
        arrival_date=DateTime(2025, 1, 5),
        max_delivery_time=Day(3), size=5.0,
        forbidden_node_ids=["B"]
    ),
    Commodity(;
        origin_id="A", destination_id="D",
        arrival_date=DateTime(2025, 1, 5),
        max_delivery_time=Day(3), size=5.0,
        forbidden_arcs=[("A", "C")]
    ),
]

# After bundling, the bundle will have BOTH constraints:
# - forbidden_node_ids = ["B"]
# - forbidden_arcs = [("A", "C")]
```

This ensures that all commodities in a bundle respect their individual restrictions.
