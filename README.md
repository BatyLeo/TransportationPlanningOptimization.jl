# TransportationPlanningOptimization.jl

[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/)
[![Build Status](https://github.com/BatyLeo/TransportationPlanningOptimization.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/BatyLeo/TransportationPlanningOptimization.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/BatyLeo/TransportationPlanningOptimization.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/BatyLeo/TransportationPlanningOptimization.jl)
[![Code Style: Blue](https://img.shields.io/badge/code%20style-blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![Aqua](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl)

A Julia package for solving multi-commodity transportation planning problems on time-expanded networks.

Given a set of commodities (each with an origin, destination, delivery deadline, and size), a network of nodes connected by arcs (each with a travel time and cost function), and a discrete time horizon, the package finds routes that minimize total transportation cost while respecting delivery constraints.

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

Requires Julia 1.11+.

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

## Data Model

Commodities are grouped automatically during instance construction:

- **Commodity** -> **Order** (commodities sharing the same origin, destination, and delivery date)
- **Order** -> **Bundle** (orders sharing the same origin and destination)

Routing operates on bundles.
The network is expanded into three graph layers:

- **NetworkGraph**: spatial network of nodes and arcs
- **TimeSpaceGraph**: time-expanded graph for tracking order-level timing
- **TravelTimeGraph**: travel-time-expanded graph used for bundle routing via Dijkstra

## Documentation

Full documentation is available [here](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/).

- **[Getting Started](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/getting_started/)**: core concepts and the `Instance` constructor
- **[Tutorials](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/tutorials/basic_example/)**: hands-on examples
- **Guides**:
  - [Algorithm Pipeline](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/guides/algorithm_pipeline/): construction heuristics, filtering, local search
  - [Cost Functions](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/guides/cost_functions/): arc costs, node costs, custom cost functions
  - [Forbidden Constraints](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/guides/forbidden_constraints/): restricting routes per commodity
  - [Multi-Modal Arcs](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/guides/multi_modal_arcs/): multiple transport modes per edge
  - [Solution I/O](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/guides/solution_io/): saving and loading solutions
- **[API Reference](https://BatyLeo.github.io/TransportationPlanningOptimization.jl/dev/api/)**: complete type and function documentation
