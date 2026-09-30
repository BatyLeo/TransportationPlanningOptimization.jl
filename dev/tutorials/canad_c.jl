# ```@meta
# CurrentModule = TransportationPlanningOptimization
# ```

# # Unsplittable Multicommodity Flow and Network Design (Canad C)
#
# This tutorial solves a public benchmark for the Unsplittable Multicommodity Flow
# Problem (UMCF), and its Multicommodity Flow Network Design Problem (MCFND) variant
# obtained from the same data by adding a fixed cost to each arc.

# ## The Problem
#
# The instances were introduced by Crainic, Frangioni, and Gendron (2001) and are
# hosted by the CommaLab (University of Pisa).
# Each instance is a directed network with arcs ``a \in A`` and commodities
# ``m \in M``, and every commodity must be routed on a single path from its origin to
# its destination, subject to arc capacities ``u_a``.
# Let ``x_a^m`` indicate that commodity ``m`` is routed through arc ``a``, ``\ell_m``
# its size, and ``c_a^m`` the cost of routing commodity ``m`` through arc ``a``.
# The UMCF is
#
# ```math
# \min \sum_{m} \sum_{a} c_a^m x_a^m
# \quad \text{s.t.} \quad \sum_{m} \ell_m x_a^m \le u_a, \quad x \in \{0, 1\}
# ```
#
# with flow conservation holding for each commodity at every node.
# For Canad C instances, ``c_a^m`` is the arc's unit variable cost times the demand
# ``\ell_m``.
#
# The MCFND variant adds a binary design variable ``y_a`` per arc, equal to 1 when arc
# ``a`` is activated, at a fixed activation cost ``c_a`` (the arc fixed cost of the
# Canad data, distinct from the routing cost ``c_a^m``):
#
# ```math
# \min \sum_{m} \sum_{a} c_a^m x_a^m + \sum_{a} c_a y_a
# \quad \text{s.t.} \quad \sum_{m} \ell_m x_a^m \le u_a y_a, \quad x, y \in \{0, 1\}
# ```
#
# Data are downloaded on demand from the CommaLab collection using DataDeps.jl.

using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.MultiCommodityFlow

list_instances(CanadC())

# ## Unsplittable Multicommodity Flow
#
# We load the `c33` data (nominal size `20-230-40`) with the default
# `network_design=false`, giving the UMCF version of the data: each arc only carries a
# [`LinearArcCost`](@ref) on the routed volume, with a hard capacity.
# Each commodity forms its own bundle.
# The instance is generated randomly, so its realized size (20 nodes, 228 arcs, 39
# commodities) differs slightly from the nominal name.

instance = load_instance(CanadC(), "c33")

# We first build a solution with the greedy insertion heuristic, then refine it with
# local search.
# To keep run times reproducible across machines, we stop on a fixed iteration
# budget (`max_iter`) rather than on wall-clock time, and raise `max_no_improv` to
# match so it does not cut the run short before that budget is reached.
# `time_limit` is kept as a generous safety cap, and the run uses a seeded RNG:

using Random

ls_kwargs = (; max_iter=250_000, max_no_improv=250_000, time_limit=30.0)

solution = greedy_heuristic(instance; show_progress=false)
is_feasible(solution, instance; verbose=true)
greedy_cost = cost(solution)

local_search!(solution, instance; ls_kwargs..., rng=MersenneTwister(0))
is_feasible(solution, instance; verbose=true)
ls_cost = cost(solution)

# [`Problems.MultiCommodityFlow.benchmark_solve`](@ref) solves the exact UMCF MIP with
# JuMP (HiGHS by default), giving the optimal value (up to the solver MIP gap) as the
# gap reference.
# It returns the solved `Instance` and a `Solution` of it, which we check for
# feasibility:

umcf_result = benchmark_solve(CanadC(), "c33")
umcf_result.termination_status
is_feasible(umcf_result.solution, umcf_result.instance; verbose=true)
umcf_optimum = umcf_result.objective_value

greedy_gap = (greedy_cost - umcf_optimum) / umcf_optimum * 100
ls_gap = (ls_cost - umcf_optimum) / umcf_optimum * 100

(greedy_gap_pct=round(greedy_gap; digits=2), ls_gap_pct=round(ls_gap; digits=2))

# ## Network Design
#
# Passing `network_design=true` gives the MCFND version of the same data: each arc
# additionally gets a [`BinPackingArcCost`](@ref), next to its [`LinearArcCost`](@ref),
# whose bin capacity equals the arc capacity, so at most one bin is ever used and the
# fixed cost is paid exactly once per used arc.
# [`cost`](@ref) applied to a solution therefore returns exactly the objective value
# of the MCFND problem above.

design_instance = load_instance(CanadC(), "c33"; network_design=true)

design_solution = greedy_heuristic(design_instance; show_progress=false)
is_feasible(design_solution, design_instance; verbose=true)
design_greedy_cost = cost(design_solution)

local_search!(design_solution, design_instance; ls_kwargs..., rng=MersenneTwister(0))
is_feasible(design_solution, design_instance; verbose=true)
design_ls_cost = cost(design_solution)

# The reference value for `c33` (instance `20-230-40-V-L`) is 423933, proven optimal
# (arXiv 2512.25018, Table F.10, which calls this variant the unsplittable
# multicommodity capacitated network design problem, MCND).

design_optimum = 423_933
design_greedy_gap = (design_greedy_cost - design_optimum) / design_optimum * 100
design_ls_gap = (design_ls_cost - design_optimum) / design_optimum * 100
