# [Cost Functions](@id cost_functions_guide)

TransportationPlanningOptimization.jl supports two types of cost functions for arcs, each suited to different transportation scenarios.

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

## Advanced: Custom Cost Functions

To implement custom cost logic, create a new type that subtypes `AbstractArcCostFunction` and implement the required interface. See the API reference for details on the cost function interface.
