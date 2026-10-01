# ```@meta
# CurrentModule = TransportationPlanningOptimization
# ```

# # Inbound Transportation Planning (Renault)
#
# This tutorial solves a regional instance of the Renault inbound transportation planning problem with [`solve`](@ref), which combines a construction heuristic and local search.

# ## The Problem
#
# Commodities must travel from suppliers to plants through a network of intermediate points (cross-docks, warehouses).
# Each commodity follows a single path, and all commodities of a bundle (same supplier and plant) share it.
# Time is discretized in weekly steps over a cyclic horizon (`wrap_time=true`), so the network is repeated week after week.
#
# The cost of using an arc is the sum of three terms:
#
# ```math
# c_a = c_a^{\text{transport}} + c_a^{\text{carbon}} + c_a^{\text{stock}}
# ```
#
# - the transport cost is either a [`LinearArcCost`](@ref) on the shipped volume, or a [`BinPackingArcCost`](@ref) on non-linear legs, where commodities are packed into vehicles (bins) and each bin has a fixed price,
# - the carbon cost is a [`LinearArcCost`](@ref) on the shipped volume,
# - the stock cost is a [`Problems.Inbound.StockArcCost`](@ref), proportional to the arc distance and to the stock cost of the shipped commodities.
#
# Nodes additionally carry a [`LinearNodeCost`](@ref) on the volume handled.
# The objective is to minimize the total cost.

# ## Loading the data
#
# The `RenaultInbound` dataset is downloaded on demand from Zenodo using DataDeps.jl.

using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound
using Random

list_instances(RenaultInbound())

# We load the regional `small` instance.

instance = load_instance(RenaultInbound(), "small")
(bundles=bundle_count(instance), commodities=commodity_count(instance))

# ## Construction
#
# [`solve`](@ref) is the recommended entry point.
# It pre-routes the bundles whose best path is the direct arc, builds an initial solution for the remaining bundles with a mix of greedy and lower-bound insertion, then merges everything back onto the full instance.
# With `local_search=false` it stops after this construction phase.
# This filtering is what keeps the construction fast on large instances, where [`greedy_heuristic`](@ref) on the full instance takes much longer.

construction = solve(instance; local_search=false, show_progress=false)
is_feasible(construction, instance; verbose=true)
construction_cost = cost(construction)

# ## Local search
#
# By default [`solve`](@ref) then improves the solution with [`local_search!`](@ref) on the filtered sub-instance.
# To keep run times reproducible across machines, we stop on a fixed iteration budget (`max_iter`).
# `time_limit` is only a generous safety cap, and the run uses a seeded RNG.

solution = solve(
    instance; max_iter=6_000, time_limit=120.0, rng=MersenneTwister(0), show_progress=false
)
is_feasible(solution, instance; verbose=true)
ls_cost = cost(solution)

# Improvement of local search over the construction solution:

improvement = (construction_cost - ls_cost) / construction_cost * 100
(improvement_pct=round(improvement; digits=2),)

# ## Using your own data
#
# Custom instances can be built from three CSV files with [`Problems.Inbound.parse_inbound_instance`](@ref), see the [Problems](../problems.md) page for details.
