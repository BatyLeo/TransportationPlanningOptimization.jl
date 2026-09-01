```@meta
CurrentModule = TransportationPlanningOptimization
```

# TransportationPlanningOptimization.jl

A Julia package for solving transportation planning problems.

## Features

- **Multi-commodity routing** over time-expanded transportation networks
- **Flexible cost models**: linear costs (`LinearArcCost`), bin-packing costs (`BinPackingArcCost`), composite costs (`SumArcCost`), and custom node costs
- **Multi-modal arcs**: multiple transport modes on the same edge with automatic mode selection
- **Routing constraints**: forbidden nodes and arcs per commodity
- **Construction heuristics**: greedy, lower-bound relaxation, and a blended strategy
- **Local search**: bundle reintroduction and two-node consolidation with configurable stopping criteria
- **Solution I/O**: save and reload solutions as CSV

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

# Improve with local search
local_search!(solution, instance; time_limit=60.0)

# Validate and evaluate
is_feasible(solution, instance; verbose=true)
println("Total cost: ", cost(solution))
```

## Documentation Structure

```@contents
Pages = [
    "getting_started.md",
    "tutorials/basic_example.md",
    "guides/algorithm_pipeline.md",
    "guides/cost_functions.md",
    "guides/forbidden_constraints.md",
    "guides/multi_modal_arcs.md",
    "guides/solution_io.md",
    "guides/type_transformations.md",
    "api.md",
]
Depth = 1
```
