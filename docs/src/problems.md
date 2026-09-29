```@meta
CurrentModule = TransportationPlanningOptimization
```

# Problems

`Problems` gathers representative transportation planning problems built on top of the package.
Load a problem submodule explicitly, for example `using TransportationPlanningOptimization.Problems.Inbound`.

Benchmark datasets share a common interface, [`Problems.AbstractDataset`](@ref).
A dataset `ds` implements [`Problems.load_instance`](@ref) to load one of its instances as an `Instance`.
It also implements [`Problems.list_instances`](@ref) to enumerate its instance names and [`Problems.dataset_dir`](@ref) to locate its files locally.
Each problem module also provides a public, non-exported `datasets()` listing its datasets, so callers can sweep over every instance with `for ds in SomeProblem.datasets(), name in list_instances(ds)`.
Problems with a reference solver also implement [`Problems.benchmark_solve`](@ref).

## Inbound

The inbound problem models the delivery of supplier commodities to plants through a network of intermediate points (cross-docks, warehouses).
An instance is built from three CSV files: a node file (points, with type `supplier`, `plant`, or other, a per-unit `node_cost`, and a capacity), a leg file (arcs between points, with a shipment cost, a capacity, a travel time in weeks, a distance, a carbon cost, and whether the leg is linear or bin-packed), and a commodity file (supplier-to-plant flows with a size, quantity, arrival date, max delivery time, and a lead-time/stock cost).
Each arc carries a sum of three cost terms: a base transport cost ([`LinearArcCost`](@ref) or [`BinPackingArcCost`](@ref) depending on the leg's `is_linear` column), a [`LinearArcCost`](@ref) on carbon emissions, and a [`Problems.Inbound.StockArcCost`](@ref) proportional to the arc's distance and the commodities' stock cost (read from `InboundCommodityInfo`).
Nodes use [`LinearNodeCost`](@ref) for per-unit storage/handling cost.

```julia
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound: parse_inbound_instance
using Dates: Week

datadir = joinpath(@__DIR__, "..", "..", "test", "public")
(; nodes, arcs, commodities) = parse_inbound_instance(
    joinpath(datadir, "tiny_nodes.csv"),
    joinpath(datadir, "tiny_legs.csv"),
    joinpath(datadir, "tiny_commodities.csv"),
)

instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
solution = greedy_heuristic(instance)
is_feasible(solution, instance; verbose=true)
cost(solution)
```

The [`Problems.Inbound.RenaultInbound`](@ref) dataset gives access to nine Renault instances, from the regional `small` to the worldwide `world5`, with weekly time steps.
They are downloaded on demand from Zenodo ([DOI 10.5281/zenodo.17234091](https://doi.org/10.5281/zenodo.17234091), CC-BY-4.0) via [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl).
They come from the paper "Optimizing a Worldwide-scale Shipper Transportation Planning in a Carmaker Supply Chain" ([arXiv 2509.07576](https://arxiv.org/abs/2509.07576)), which should be cited when using them.

```julia
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound

list_instances(RenaultInbound())
instance = load_instance(RenaultInbound(), "small")
solution = greedy_heuristic(instance)
```

## Multicommodity flow

The `MultiCommodityFlow` module gives access to public benchmark instances for multicommodity flow problems, currently the Canad C instances, which carry, for each arc, a variable cost, a capacity and a fixed cost.
Instances are downloaded on demand from the CommaLab (University of Pisa) collection via [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl).
By default (`network_design=false`), each arc only gets a [`LinearArcCost`](@ref) on the routed demand while keeping the arc's capacity, giving the Unsplittable Multicommodity Flow Problem (UMCF) version of the data.
With `network_design=true`, each arc additionally gets a [`BinPackingArcCost`](@ref) whose bin capacity equals the arc's capacity, matching the Multicommodity Flow Network Design Problem (MCFND) objective (since at most one bin can ever be used, the fixed cost is paid exactly once per used arc).
The published reference values for these instances (arXiv 2512.25018, Table F.10) refer to the MCFND version, which that paper calls the unsplittable multicommodity capacitated network design problem (MCND).

[`Problems.MultiCommodityFlow.benchmark_solve`](@ref) solves the exact MIP for either variant with JuMP, using HiGHS by default (pass any JuMP-compatible optimizer factory through the `optimizer` keyword, for instance `gurobi_optimizer` once `Gurobi.jl` is loaded).
It returns the solved `Instance` and a `Solution` of it.
`objective_value` equals `cost(res.solution)`, so it compares directly with heuristic solutions of `res.instance` (via [`greedy_heuristic`](@ref) or [`local_search!`](@ref)).

```julia
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.MultiCommodityFlow

list_instances(CanadC())
MultiCommodityFlow.dataset_dir(CanadC())
res = benchmark_solve(CanadC(), "c33")
is_feasible(res.solution, res.instance; verbose=true)

sol = greedy_heuristic(res.instance)
cost(sol), res.objective_value
```

See the [Canad C tutorial](tutorials/canad_c.md) for a full walkthrough with the greedy heuristic and local search.

```@autodocs
Modules = [
    TransportationPlanningOptimization.Problems,
    TransportationPlanningOptimization.Problems.Inbound,
    TransportationPlanningOptimization.Problems.MultiCommodityFlow,
]
```
