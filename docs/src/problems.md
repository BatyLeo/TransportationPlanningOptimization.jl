```@meta
CurrentModule = TransportationPlanningOptimization
```

# Problems

`Problems` gathers representative transportation planning problems built on top of the package.
Each problem is a submodule that relies only on the package's public API.
Load a problem submodule explicitly, for example `using TransportationPlanningOptimization.Problems.Inbound`.

Benchmark datasets share a common interface, [`Problems.AbstractDataset`](@ref).
A dataset `ds` implements [`Problems.list_instances`](@ref) to enumerate its instance names, [`Problems.dataset_dir`](@ref) to locate its files locally, and [`Problems.load_instance`](@ref) to build an `Instance`, with dataset-specific keywords selecting problem variants.
Each problem module also provides a public, non-exported `datasets()` listing its datasets, so callers can sweep over every instance with `for ds in SomeProblem.datasets(), name in list_instances(ds)`.

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

## Multicommodity flow

The `MultiCommodityFlow` module gives access to public benchmark instances for multicommodity flow problems, currently the Canad C instances of the fixed-charge multicommodity capacitated network design (MCND) problem.
Instances are downloaded on demand from the CommaLab (University of Pisa) collection via [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl).
By default (`fixed_costs=true`), each arc is encoded as a [`LinearArcCost`](@ref) on the routed demand plus a [`BinPackingArcCost`](@ref) whose bin capacity equals the arc's capacity, matching the fixed-charge network design objective (since at most one bin can ever be used, the fixed cost is paid exactly once per used arc).
With `fixed_costs=false`, each arc only gets the [`LinearArcCost`](@ref) while keeping the same capacity, giving the unsplittable multicommodity flow (UMCF) version of the same data.

```julia
using TransportationPlanningOptimization.Problems.MultiCommodityFlow

list_instances(CanadC())
MultiCommodityFlow.dataset_dir(CanadC())
instance = load_instance(CanadC(), "c33")
```

See the [Canad C tutorial](tutorials/canad_c.md) for a full walkthrough with the greedy heuristic and local search.

```@autodocs
Modules = [
    TransportationPlanningOptimization.Problems,
    TransportationPlanningOptimization.Problems.Inbound,
    TransportationPlanningOptimization.Problems.MultiCommodityFlow,
]
```
