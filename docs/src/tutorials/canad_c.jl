# # Multicommodity network design (Canad C)
#
# This tutorial solves a public benchmark for the fixed-charge multicommodity
# capacitated network design (MCND) problem, and its unsplittable multicommodity flow
# (UMCF) variant obtained from the same data by dropping the fixed costs.

# ## The Problem
#
# The instances were introduced by Crainic, Frangioni, and Gendron (2001) and are
# hosted by the CommaLab (University of Pisa).
# Each instance is a directed network where every commodity must be routed on a
# single path from its origin to its destination.
# The objective sums, over the used arcs, a variable cost proportional to the routed
# demand plus a fixed cost paid once per arc, subject to arc capacities:
#
# ```math
# \min \sum_{(i,j)} \left( c_{ij} \sum_{k} x^k_{ij} d_k + f_{ij} y_{ij} \right)
# \quad \text{s.t.} \quad \sum_k x^k_{ij} d_k \le u_{ij} y_{ij}
# ```
#
# where ``x^k_{ij}`` indicates that commodity ``k`` is routed through arc ``(i, j)``,
# ``d_k`` is its demand, ``y_{ij}`` indicates that the arc is used, and ``u_{ij}`` is
# its capacity.
# Flow conservation holds for each commodity at every node, and both ``x`` and ``y``
# are binary.
# Data are downloaded on demand from the CommaLab collection using DataDeps.jl.

# ## Loading an Instance

using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.MultiCommodityFlow

list_instances(CanadC())

# We load the `c33` instance (nominal size `20-230-40`) and print its summary.
# Each Canad C commodity has a single origin, destination, and delivery date, and no
# two commodities of an instance share the same origin-destination pair, so each
# commodity maps to exactly one bundle.
# The instance is generated randomly, so its realized size (20 nodes, 228 arcs, 39
# commodities) differs slightly from the nominal name.

instance = load_instance(CanadC(), "c33")

# ## Encoding
#
# Each arc combines a [`LinearArcCost`](@ref) on the routed volume with a
# [`BinPackingArcCost`](@ref) whose bin capacity equals the arc's capacity, so at
# most one bin is ever used and the fixed cost is paid exactly once per used arc.
# [`cost`](@ref) applied to a solution therefore returns exactly the objective value
# of the network design problem above.

# ## Greedy Heuristic
#
# We first build a solution with the greedy insertion heuristic:

solution = greedy_heuristic(instance)
is_feasible(solution, instance; verbose=true)

# The reference value for `c33` (instance `20-230-40-V-L`) is 423933, proven optimal
# (arXiv 2512.25018, Table F.10).

greedy_cost = cost(solution)
optimum = 423_933
greedy_gap = (greedy_cost - optimum) / optimum * 100

# ## Local Search
#
# We then refine the solution with local search.
# To keep run times reproducible across machines, we stop on a fixed iteration
# budget (`max_iter`) rather than on wall-clock time, and raise `max_no_improv` to
# match so it does not cut the run short before that budget is reached.
# `time_limit` is kept as a generous safety cap, and the run uses a seeded RNG:

using Random

ls_kwargs = (; max_iter=250_000, max_no_improv=250_000, time_limit=30.0)

local_search!(solution, instance; ls_kwargs..., rng=MersenneTwister(0))

is_feasible(solution, instance; verbose=true)

# The resulting cost and its gap to the optimum:

ls_cost = cost(solution)
ls_gap = (ls_cost - optimum) / optimum * 100

# ## Comparison Across Instances
#
# We repeat the local search step on two more instances, reusing the `c33` results
# computed above.
# `c35` (`20-230-40-V-T`) has best known value 398870.
# `c36` (`20-230-40-F-T`) has best known value 668699 (both from arXiv 2512.25018,
# Table F.10).

using DataFrames

best_known = ["c35" => 398_870, "c36" => 668_699]

rows = [(
    instance="c33",
    greedy_gap_pct=round(greedy_gap; digits=2),
    ls_gap_pct=round(ls_gap; digits=2),
)]

for (name, best) in best_known
    inst = load_instance(CanadC(), name)
    sol = greedy_heuristic(inst)
    g_cost = cost(sol)
    local_search!(sol, inst; ls_kwargs..., rng=MersenneTwister(0))
    l_cost = cost(sol)
    push!(
        rows,
        (
            instance=name,
            greedy_gap_pct=round((g_cost - best) / best * 100; digits=2),
            ls_gap_pct=round((l_cost - best) / best * 100; digits=2),
        ),
    )
end

DataFrame(rows)

# The table reports, for each instance, the gap of the greedy heuristic and of the
# local search solution to the best known value.
#
# To sweep every instance of every dataset of the problem instead of a hand-picked
# list (not run here, as it would make the documentation build too slow):
#
# ```julia
# for ds in MultiCommodityFlow.datasets(), name in list_instances(ds)
#     instance = load_instance(ds, name)
#     # ...
# end
# ```

# ## Flow Version (No Fixed Costs)
#
# Dropping the fixed cost from every arc turns the same data into an unsplittable
# multicommodity flow (UMCF) instance: commodities still route on a single path each
# and arcs still have a hard capacity, so the problem remains NP-hard, but we are not
# aware of a published reference value for it.

flow_instance = load_instance(CanadC(), "c33"; fixed_costs=false)

flow_solution = greedy_heuristic(flow_instance)
is_feasible(flow_solution, flow_instance; verbose=true)
flow_greedy_cost = cost(flow_solution)

local_search!(flow_solution, flow_instance; ls_kwargs..., rng=MersenneTwister(0))
is_feasible(flow_solution, flow_instance; verbose=true)
flow_ls_cost = cost(flow_solution)

# Arc costs are linear, so bundles do not interact through costs.
# [`lower_bound`](@ref) routes each bundle on its cheapest path while ignoring arc
# capacities, so it solves a relaxation of the UMCF and its cost is a valid lower
# bound on the optimum.
# The gaps below therefore overestimate the true optimality gaps.

flow_lb_solution = lower_bound(flow_instance)
flow_lb_cost = cost(flow_lb_solution)

flow_greedy_gap = (flow_greedy_cost - flow_lb_cost) / flow_lb_cost * 100
flow_ls_gap = (flow_ls_cost - flow_lb_cost) / flow_lb_cost * 100

(greedy_gap_pct=round(flow_greedy_gap; digits=2), ls_gap_pct=round(flow_ls_gap; digits=2))
