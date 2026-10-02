```@meta
CurrentModule = TransportationPlanningOptimization
```

# Problems

`Problems` gathers representative transportation planning problems built on top of the package.
Load a problem submodule explicitly, for example `using TransportationPlanningOptimization.Problems.Inbound`.

Benchmark datasets share a common interface, [`Problems.AbstractDataset`](@ref).
A dataset `ds` implements [`Problems.load_instance`](@ref) to load one of its instances as an `Instance`, [`Problems.list_instances`](@ref) to enumerate its instance names, and [`Problems.dataset_dir`](@ref) to locate its files locally.
Each problem module also provides a public, non-exported `datasets()` listing its datasets, so callers can sweep over every instance with `for ds in SomeProblem.datasets(), name in list_instances(ds)`.
Problems with a reference solver also implement [`Problems.benchmark_solve`](@ref).

## Inbound

The inbound problem models the delivery of supplier commodities to plants through a network of intermediate points (cross-docks, warehouses).
An instance is built from three CSV files: a node file (points, with their type, a per-unit cost and a capacity), a leg file (arcs between points, with costs, capacity, travel time in weeks and distance), and a commodity file (supplier-to-plant flows with a size, quantity, arrival date, maximum delivery time and stock cost).

Each arc cost is the sum of three terms:

- a base transport cost ([`LinearArcCost`](@ref) or [`BinPackingArcCost`](@ref) depending on the leg's `is_linear` column),
- a [`LinearArcCost`](@ref) on carbon emissions,
- a [`Problems.Inbound.StockArcCost`](@ref) proportional to the arc's distance and to the stock cost of the commodities (read from `InboundCommodityInfo`).

Nodes use a [`LinearNodeCost`](@ref) for the per-unit handling cost.
The parser drops legs with missing values, keeps only the first leg of each duplicated (origin, destination) pair, and scales volumes and capacities by 100.

The [`Problems.Inbound.RenaultInbound`](@ref) dataset gives access to nine Renault instances, from the regional `small` to the worldwide `world5`, with weekly time steps.
By default, the commodity dates are rebuilt from the `delivery_time_step` column (`minimum(delivery_date) + Week(step)`), which reproduces the time model of the reference implementation (a 26-step cyclic horizon on `world2` to `world5`, where the steps do not follow the calendar).
Pass `dates_from_time_step=false` to `load_instance` or `parse_inbound_instance` to read the real `delivery_date` instead.
Both readings agree on `small` to `world`.
They are downloaded on demand from Zenodo ([DOI 10.5281/zenodo.17234091](https://doi.org/10.5281/zenodo.17234091), CC-BY-4.0) via [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl).
They come from the paper "Optimizing a Worldwide-scale Shipper Transportation Planning in a Carmaker Supply Chain" ([arXiv 2509.07576](https://arxiv.org/abs/2509.07576)).

To use your own data, parse the three CSV files and build the instance with weekly time steps:

```julia
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound: parse_inbound_instance
using Dates: Week

(; nodes, arcs, commodities) = parse_inbound_instance(
    "nodes.csv", "legs.csv", "commodities.csv"
)
instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
```

See the [Inbound tutorial](tutorials/inbound.md) for a full walkthrough with `solve`.

## Unsplittable Multicommodity Flow

The `MultiCommodityFlow` module gives access to public benchmark instances for multicommodity flow problems, currently the Canad C instances, which carry, for each arc, a variable cost, a capacity and a fixed cost.
Instances are downloaded on demand from the CommaLab (University of Pisa) collection via [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl).
By default (`network_design=false`), each arc only gets a [`LinearArcCost`](@ref) on the routed demand while keeping the arc's capacity, giving the Unsplittable Multicommodity Flow Problem (UMCF) version of the data.
With `network_design=true`, each arc additionally gets a [`BinPackingArcCost`](@ref) whose bin capacity equals the arc's capacity, matching the Multicommodity Flow Network Design Problem (MCFND) objective (since at most one bin can ever be used, the fixed cost is paid exactly once per used arc).
The published reference values for these instances (arXiv 2512.25018, Table F.10) refer to the MCFND version, which that paper calls the unsplitable multicommodity capacitated network design problem (MCND).

[`Problems.MultiCommodityFlow.benchmark_solve`](@ref) solves the exact MIP for either variant with JuMP, using HiGHS by default (pass any JuMP-compatible optimizer factory through the `optimizer` keyword, for instance `gurobi_optimizer` once `Gurobi.jl` is loaded).
It returns the solved `Instance` and a `Solution` of it.
`objective_value` equals `cost(res.solution)`, so it compares directly with heuristic solutions of `res.instance` (for instance via [`solve`](@ref)).

```julia
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.MultiCommodityFlow

res = benchmark_solve(CanadC(), "c33")
cost(solve(res.instance)), res.objective_value
```

See the [Canad C tutorial](tutorials/canad_c.md) for a full walkthrough with `solve`.

## API

```@autodocs
Modules = [
    TransportationPlanningOptimization.Problems,
    TransportationPlanningOptimization.Problems.Inbound,
    TransportationPlanningOptimization.Problems.MultiCommodityFlow,
]
```
