```@meta
CurrentModule = TransportationPlanningOptimization
```

# TransportationPlanningOptimization.jl

A Julia package for solving transportation planning problems.

## Features

- **Multi-commodity flow** over transportation networks with time-dependent routing
- **Multiple cost models**: Support for linear costs (proportional to volume) and bin packing costs (discrete per vehicle/container)
- **Routing constraints**: option to model forbidden nodes and arcs restrictions
- **Time discretization**: handle delivery deadlines and transit times with flexible time steps
- **Efficient algorithms**: greedy heuristics for fast and good quality solution generation

## Installation

```julia
using Pkg
Pkg.add("https://github.com/BatyLeo/TransportationPlanningOptimization.jl")
```

## Quick Start

```julia
using TransportationPlanningOptimization
using Dates

# Define network nodes
nodes = [
    NetworkNode(; id="Origin", node_type=:origin),
    NetworkNode(; id="Hub", node_type=:other),
    NetworkNode(; id="Destination", node_type=:destination),
]

# Define transportation arcs
arcs = [
    Arc(; origin_id="Origin", destination_id="Hub",
         cost=LinearArcCost(10.0), travel_time=Day(1)),
    Arc(; origin_id="Hub", destination_id="Destination",
         cost=LinearArcCost(10.0), travel_time=Day(1)),
]

# Define commodities to transport
commodities = [
    Commodity(;
        origin_id="Origin",
        destination_id="Destination",
        arrival_date=DateTime(2025, 1, 3),
        max_delivery_time=Day(2),
        size=5.0,
    ),
]

# Create instance and solve
instance = Instance(nodes, arcs, commodities, Day(1))
solution = greedy_heuristic(instance)

# Validate and evaluate
is_feasible(solution, instance; verbose=true)
println("Total cost: ", cost(solution))
```

## Documentation Structure

```@contents
Pages = [
    "getting_started.md",
    "tutorials/basic_example.md",
    "tutorials/csv_example.md",
    "guides/cost_functions.md",
    "guides/forbidden_constraints.md",
    "api.md",
]
Depth = 1
```
