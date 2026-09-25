```@meta
CurrentModule = TransportationPlanningOptimization
```

# Problems

`Problems` gathers representative transportation planning problems built on top of the package.
Each problem is a submodule that relies only on the package's public API.
Load a problem submodule explicitly, for example `using TransportationPlanningOptimization.Problems.Inbound`.

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

The `MultiCommodityFlow` module gives access to public benchmark instances for multicommodity flow problems, currently the Canad C instances of the multicommodity capacitated fixed-charge network design problem.
Instances are downloaded on demand from the CommaLab (University of Pisa) collection via [DataDeps.jl](https://github.com/oxinabox/DataDeps.jl).
The code block below is illustrative only and is not run when building the docs, since it would trigger a download.

```julia
using TransportationPlanningOptimization.Problems.MultiCommodityFlow

list_instances(CanadC())
dataset_dir(CanadC())
```

```@autodocs
Modules = [
    TransportationPlanningOptimization.Problems,
    TransportationPlanningOptimization.Problems.Inbound,
    TransportationPlanningOptimization.Problems.MultiCommodityFlow,
]
```
