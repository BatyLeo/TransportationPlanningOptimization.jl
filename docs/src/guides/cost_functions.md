# [Cost Functions](@id cost_functions_guide)

TransportationPlanningOptimization.jl supports cost functions on both arcs and nodes.
Arc costs are the primary cost model, while node costs add per-node contributions (e.g., storage or handling fees).

## Arc Cost Functions

## LinearArcCost

`LinearArcCost` represents costs that scale proportionally with the volume or size of commodities transported.

### Constructor

```julia
LinearArcCost(cost_per_unit_size::Float64)
```

### Cost Calculation

The total cost on an arc is computed as:

```
cost = cost_per_unit_size * total_size_of_commodities
```

### Example

```julia
using TransportationPlanningOptimization
using Dates

arc = Arc(;
    origin_id="A",
    destination_id="B",
    cost=LinearArcCost(5.0),
    travel_time=Day(1)
)
```

---

## BinPackingArcCost

`BinPackingArcCost` represents discrete costs based on the number of vehicles, containers, or bins needed to transport commodities.

### Constructor

```julia
BinPackingArcCost(cost_per_bin::Float64, bin_capacity::Int)
```

### Cost Calculation

Commodities are packed into bins using a (1 dimensional) **First-Fit Decreasing (FFD)** heuristic:
1. Sort commodities by size (largest first)
2. For each commodity, assign it to the first bin with sufficient remaining capacity
3. Open a new bin if no existing bin can fit the commodity

The total cost is:

```
cost = cost_per_bin * number_of_bins_needed
```

### Example

```julia
using TransportationPlanningOptimization
using Dates

arc = Arc(;
    origin_id="A",
    destination_id="B",
    cost=BinPackingArcCost(100.0, 10),
    travel_time=Day(1)
)
```

---

## Mixed Networks

You can combine both cost types in the same network:

```julia
arcs = [
    Arc(; 
        origin_id="Port", 
        destination_id="Warehouse",
        cost=BinPackingArcCost(1000.0, 20),
        travel_time=Week(2)
    ),
    
    Arc(;
        origin_id="Warehouse",
        destination_id="Customer",
        cost=LinearArcCost(15.0),
        travel_time=Day(1)
    ),
]
```

This flexibility allows modeling realistic multi-modal transportation networks where different segments have different cost structures.

---

## SumArcCost

[`SumArcCost`](@ref) combines multiple cost terms on a single arc.
The total cost is the sum of each term's cost.
This is useful when an arc has both a per-vehicle cost and a per-unit handling fee, for example.

### Constructor

```julia
SumArcCost((BinPackingArcCost(100.0, 10), LinearArcCost(2.0)))
```

The argument is a tuple of [`AbstractArcCostFunction`](@ref) instances.
At most one term may be a [`BinPackingArcCost`](@ref) (bin-packing methods dispatch to that term).

### Example

```julia
using TransportationPlanningOptimization
using Dates

# An arc with both a truck cost and a per-unit handling fee
arc = Arc(;
    origin_id="Warehouse",
    destination_id="Customer",
    cost=SumArcCost((BinPackingArcCost(500.0, 20), LinearArcCost(3.0))),
    travel_time=Day(1),
)
```

---

## Node Cost Functions

Node costs add per-node cost contributions on top of arc costs.
They are evaluated at every node a bundle passes through, based on the commodities transiting that node.

By default, nodes use [`NoNodeCost`](@ref) (zero cost).
To add a node cost, pass a `node_cost` keyword to [`NetworkNode`](@ref):

```julia
NetworkNode(; id="Hub", node_type=:other, node_cost=my_custom_cost)
```

### Implementing a custom node cost

Subtype [`AbstractNodeCostFunction`](@ref) and implement `evaluate`:

```julia
struct HandlingCost <: AbstractNodeCostFunction
    cost_per_unit::Float64
end

function TransportationPlanningOptimization.evaluate(
    c::HandlingCost, commodities::Vector{<:LightCommodity}
)
    return c.cost_per_unit * sum(comm.size for comm in commodities)
end
```

Optionally override `incremental_cost(c, existing, new)` for efficiency (the default computes `evaluate(c, existing + new) - evaluate(c, existing)`, which allocates a temporary vector).
Override `lower_bound_incremental_cost` only when the lower-bound relaxation differs from the true incremental cost.

---

## Custom Arc Cost Functions

To implement custom arc cost logic, create a new type that subtypes [`AbstractArcCostFunction`](@ref) and implement:

- `evaluate(c, commodities; presorted=false)`: total cost for a set of commodities.
- `incremental_cost(c, existing, new)` (optional): marginal cost of adding `new` commodities to `existing` ones.
  Defaults to `evaluate(c, existing + new) - evaluate(c, existing)`.
- `lower_bound_incremental_cost(c, existing, new)` (optional): relaxed cost used by the lower-bound pass.
  Defaults to `incremental_cost`.

See the API reference for the full interface.
