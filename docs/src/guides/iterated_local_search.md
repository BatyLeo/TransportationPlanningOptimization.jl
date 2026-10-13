# [Iterated Local Search](@id ils_guide)

[`iterated_local_search!`](@ref) escapes the local optima of [`local_search!`](@ref) by alternating perturbations and local searches.
It is a separate call, [`solve`](@ref) never runs it.

## What it does

Each round takes the next perturbation of the list (round-robin) and applies it repeatedly until enough bundles changed paths (`change_threshold_ratio` of the bundles), the accumulated cost increase reaches `cost_threshold_ratio` of the best cost, or `perturbation_time_limit` is hit.
Local search then runs only once the change threshold is reached, so small perturbations pile up before being repaired.
A solution cheaper than the best one becomes the new best, also when it is found right after a perturbation phase.
At the end the best solution is restored and polished by a final local search.
The search stops on `time_limit`, or after `max_no_change` rounds without change, or after `max_no_improv` local searches without a new best (all fields of [`ILSConfig`](@ref)).
`max_no_improv` counts the local searches with no new best since the previous one, the perturbation phases before it included.

Pass `cost_update! = slope_scaling_update!` to rescale the costs of the arcs by their bin utilization before the loop and after every local search, which makes under-filled bin-packing arcs more expensive (factor `n_bins / ceil(volume / capacity)`, between 1 and 2) in the objectives of the MILP perturbations only (see [Cost Functions](@ref cost_functions_guide)).
The factors are stored per edge group (spatial pair and transit time), and a group takes the largest factor of its time-space edges.
Local search, insertions and acceptance always use the real cost.
The cost scaling factors of the travel time graph are always emptied when [`iterated_local_search!`](@ref) returns, also when it throws, including factors set by the caller.

## Time budget

`time_limit` is the wall-clock limit of the whole call.
The last `final_ls_time_limit` seconds are reserved for the final local search, which gets at most that time and at most the time left.
By default it is `min(300, time_limit / 6)` seconds, and it cannot exceed `time_limit`.
The main loop uses the rest, and `ls_time_limit` only limits each local search phase inside it.
Each perturbation call receives the seconds it may use, the smaller of the time left in its phase (`perturbation_time_limit`) and in the main loop.
The loop starts no call with less than 1 second left, or half of the shorter limit when a limit is under 2 seconds.

With `verbose=true`, each perturbation call logs one `@info "Perturbation"` line.
It gives the type, the outcome (accepted or the reason of the rejection), `cost_increase` and `n_changed`.
[`GroupReinsertPerturbation`](@ref) logs its rejected calls at debug level, because it is cheap and called many times per phase.
The MILP perturbations add the size of the model, the build and solve times, the solver status and the gap.

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

[`AttractReduceMILPPerturbation`](@ref) prices the new paths against the current solution without removing the bundle first when no arc has a finite capacity, and removes it otherwise.
It stops pricing at half of the call budget, also inside an arc.

All of them keep the new routing only if the real cost increase is at most `tolerance` times the current cost, and otherwise restore the solution exactly.
Both MILP perturbations raise an `ArgumentError` on instances with multimodal arcs.
[`iterated_local_search!`](@ref) therefore skips the perturbations for which [`supports_instance`](@ref) returns `false` (logged once when `verbose`) and throws an `ArgumentError` when none is left.

## Solver choice

The MILP perturbations take an `optimizer` keyword, HiGHS by default.
With [Gurobi.jl](https://github.com/jump-dev/Gurobi.jl) loaded, use the optimizer of the Gurobi extension:

```julia
using Gurobi
p = ArcFlowMILPPerturbation(; optimizer=gurobi_optimizer)
```

The MILP perturbations use the smaller of their own `solver_time_limit` field and the call budget, and the copy of the model to the solver counts in that budget.
HiGHS presolve can exceed the time limit on large models, so for [`ArcFlowMILPPerturbation`](@ref) the variable cap `max_variables` is what bounds the runtime.

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
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    # modify `sol`, then return (cost_increase, n_changed)
end
```

Overload [`supports_instance`](@ref)`(p, instance)` to return `false` when the perturbation cannot run on an instance, the default is `true`.

`time_limit` is the number of seconds the call may use.
Return `(0.0, 0)` without changing the solution when the time is too short to be useful.

`mode_selector` is the one given to [`iterated_local_search!`](@ref), the same as for the rest of the pipeline.
Use it for every path insertion, for instance `TransportationPlanningOptimization.add_bundle_path!(sol, instance, b, path; mode_selector)`.

The method returns `(cost_increase, n_changed)`: the cost after minus the cost before, and the number of bundles whose path changed.
When it rejects its own move, it must restore `sol` exactly and return `(0.0, 0)`.
The solution must stay feasible.
[`snapshot_solution`](@ref) and [`restore_solution!`](@ref) give a full copy and rollback if you do not need a cheaper local one.
