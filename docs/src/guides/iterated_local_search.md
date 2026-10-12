# [Iterated Local Search](@id ils_guide)

[`iterated_local_search!`](@ref) escapes the local optima of [`local_search!`](@ref) by alternating perturbations and local searches.
It is a separate call, [`solve`](@ref) never runs it.

## What it does

Each round takes the next perturbation of the list (round-robin) and applies it repeatedly until enough bundles changed paths (`change_threshold_ratio` of the bundles), the accumulated cost increase reaches `cost_threshold_ratio` of the best cost, or `perturbation_time_limit` is hit.
Local search then runs only once the change threshold is reached, so small perturbations pile up before being repaired.
A solution cheaper than the best one becomes the new best, and the best solution is restored and polished at the end.
The search stops on `time_limit`, or after `max_no_change` rounds without change, or after `max_no_improv` local searches without a new best (all fields of [`ILSConfig`](@ref)).

Pass `cost_update! = slope_scaling_update!` to rescale the costs of the arcs by their bin utilization before the loop and after every local search, which makes under-filled bin-packing arcs more expensive (factor `n_bins / ceil(volume / capacity)`, at most 2) in the path searches of the perturbations and local searches (see [Cost Functions](@ref cost_functions_guide)).
Acceptance always uses the real cost.

## Workflow

Run it on the filtered sub-instance, then merge:

```julia
result = solve_filtered(instance)
(; solution_state, sub_instance, filtering_state) = result

ils = iterated_local_search!(
    solution_state,
    sub_instance,
    [GroupReinsertPerturbation(), AttractReduceMILPPerturbation()];
    config=ILSConfig(; time_limit=600.0),
    (cost_update!)=slope_scaling_update!,
)
# ils.best_cost, ils.improvement, ils.iterations, ils.cost_history

merged = merge_solutions(filtering_state, solution_state, instance, sub_instance)
solution = Solution(merged, instance)
is_feasible(solution, instance; verbose=true)
```

The state is modified in place and ends on the best solution found.
[`ILSResult`](@ref) reports the improvement, the best cost, the number of iterations and the cost history.

## Perturbations

- [`GroupReinsertPerturbation`](@ref): removes all the bundles of a random group (by default one destination) and reinserts them one by one along their cheapest paths.
- [`ArcFlowMILPPerturbation`](@ref): reroutes several groups at once with an arc-flow MILP, the load of the other bundles being fixed.
  The number of variables is capped by `max_variables`.
- [`AttractReduceMILPPerturbation`](@ref): picks an arc with a bin cost, gives every bundle on it a path that avoids it and every other bundle that can use it a path through it, and a MILP selects the combination that pays.

All of them keep the new routing only if the real cost increase is at most `tolerance` times the current cost, and otherwise restore the solution exactly.
Both MILP perturbations raise an `ArgumentError` on instances with multimodal arcs.

## Solver choice

The MILP perturbations take an `optimizer` keyword, HiGHS by default.
With [Gurobi.jl](https://github.com/jump-dev/Gurobi.jl) loaded, use the optimizer of the Gurobi extension:

```julia
using Gurobi
p = ArcFlowMILPPerturbation(; optimizer=gurobi_optimizer)
```

HiGHS presolve can exceed `time_limit` on large models, so for [`ArcFlowMILPPerturbation`](@ref) the variable cap `max_variables` is what bounds the runtime.

Both MILP perturbations have a `warm_start` keyword, off by default, because starting from the current routing makes time-limited solves return it again instead of diversifying.

## Custom perturbations

Subtype [`AbstractPerturbation`](@ref) and implement [`perturbate!`](@ref):

```julia
using Random

struct MyPerturbation <: AbstractPerturbation end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::MyPerturbation;
    rng=Random.default_rng(),
    verbose=false,
)
    # modify `sol`, then return (cost_increase, n_changed)
end
```

The method returns `(cost_increase, n_changed)`: the cost after minus the cost before, and the number of bundles whose path changed.
When it rejects its own move, it must restore `sol` exactly and return `(0.0, 0)`.
The solution must stay feasible.
[`snapshot_solution`](@ref) and [`restore_solution!`](@ref) give a full copy and rollback if you do not need a cheaper local one.
