# ```@meta
# CurrentModule = TransportationPlanningOptimization
# ```

# # Inbound Transportation Planning (Renault)
#
# This tutorial solves a regional instance of the Renault inbound transportation planning problem with the greedy heuristic and local search.

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

# ## Greedy heuristic
#
# The greedy heuristic inserts bundles one by one, each on its cheapest path given the bundles already placed.

solution = greedy_heuristic(instance; show_progress=false)
is_feasible(solution, instance; verbose=true)
greedy_cost = cost(solution)

# ## Local search
#
# To keep run times reproducible across machines, we stop on a fixed iteration budget (`max_iter`), and raise `max_no_improv` to match so it does not cut the run short.
# `time_limit` is only a generous safety cap, and the run uses a seeded RNG.

ls_kwargs = (; max_iter=6_000, max_no_improv=6_000, time_limit=120.0)

local_search!(solution, instance; ls_kwargs..., rng=MersenneTwister(0))
is_feasible(solution, instance; verbose=true)
ls_cost = cost(solution)

# Improvement of local search over the greedy solution:

improvement = (greedy_cost - ls_cost) / greedy_cost * 100
(improvement_pct=round(improvement; digits=2),)

# ## Using your own data
#
# Custom instances can be built from three CSV files with [`Problems.Inbound.parse_inbound_instance`](@ref), see the [Problems](../problems.md) page for details.
