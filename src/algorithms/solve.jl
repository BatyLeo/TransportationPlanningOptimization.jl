"""
$TYPEDSIGNATURES

Building block of [`solve`](@ref) for advanced workflows: run the filtered initial-solution pipeline up to (but not including) local search.

1. Run [`lower_bound_filtering`](@ref) on `instance`, pre-routing trivial bundles.
2. Build the sub-instance of non-trivial bundles via [`extract_filtered_instance`](@ref).
3. Call [`mix_greedy_heuristic`](@ref) on the sub-instance, starting from a solution pre-loaded (via [`preload_filtered_bundles`](@ref)) with the capacity and cost already claimed by the filtered-out bundles.

Returns `(; solution_state, sub_instance, filtering_state)`.
The `solution_state` lives on `sub_instance`, not on the original `instance`, and `filtering_state` is the full-instance state of step 1.
Improve `solution_state` on `sub_instance` with [`local_search!`](@ref) or [`iterated_local_search!`](@ref), then get the full-instance state with `merge_solutions(result.filtering_state, result.solution_state, instance, result.sub_instance)`.

Because `solution_state` is pre-loaded with the reserved load of every filtered bundle whose direct arc is still in `sub_instance`, `cost(result.solution_state)` is neither the sub-instance cost nor the full-instance cost.
Only the merged state has the full-instance cost.

Set `show_progress=false` to hide the progress bars.
"""
function solve_filtered(instance::Instance; show_progress::Bool=true)
    filtering_state = lower_bound_filtering(instance; show_progress)
    sub_instance = extract_filtered_instance(instance, filtering_state)
    start = preload_filtered_bundles(filtering_state, instance, sub_instance)
    solution_state = mix_greedy_heuristic(sub_instance; start, show_progress)
    return (; solution_state, sub_instance, filtering_state)
end

# State to improve for a warm start, a `SolutionState` start is copied so the caller's one is not mutated.
_start_state(start::Solution, instance::Instance) = SolutionState(start, instance)
_start_state(start::SolutionState, ::Instance) = copy(start)

"""
$TYPEDSIGNATURES

Solve `instance` and return a feasible [`SolutionState`](@ref) on it.
Most users want [`solve`](@ref), which returns the user-facing [`Solution`](@ref).
Use `solve_state` when the state is needed, for example for [`local_search!`](@ref) or [`iterated_local_search!`](@ref).

With `filtering=true` (default):

1. [`lower_bound_filtering`](@ref) fixes the bundles whose best path is the direct arc.
2. The remaining bundles form a sub-instance, solved by [`mix_greedy_heuristic`](@ref) from a start holding the load of the fixed bundles (see [`solve_filtered`](@ref)).
3. If `local_search=true`, [`local_search!`](@ref) improves the sub-instance solution.
4. [`merge_solutions`](@ref) brings the result back to the full instance.

With `filtering=false`, construction ([`mix_greedy_heuristic`](@ref)) and local search run directly on the full instance.
This is only reasonable on small instances.
Construction on the full instance is much slower on large ones, because its cost scales with the number of unit commodities times the number of bundle arcs (and so is that of [`greedy_heuristic`](@ref)).

With `start` (a [`Solution`](@ref) or a [`SolutionState`](@ref)), filtering and construction are skipped and `filtering` is ignored.
A `Solution` is converted by `SolutionState(start, instance)`, so its bins are repacked by first-fit decreasing.
A `SolutionState` is copied and the caller's one is left untouched.
The state must be feasible on `instance`, then local search runs on the full instance if `local_search=true`.
The cost of the result is at most the cost of the converted start, which can differ from `cost(start)` for bin packing costs.

`time_limit` (seconds), `max_iter` and `rng` only apply to local search, so `time_limit` does not cover construction.
Local search also stops after 15000 consecutive non-improving iterations (the [`local_search!`](@ref) default), so it can return well before `time_limit`.
All steps use [`CheapestMode`](@ref).
Set `show_progress=false` to hide the progress bars.

Throws `ArgumentError` if no feasible construction is found, if the merged solution is infeasible, if `start` cannot be represented on `instance` (see `SolutionState(solution, instance)`) or if `start` is infeasible.
"""
function solve_state(
    instance::Instance;
    start::Union{Nothing,Solution,SolutionState}=nothing,
    filtering::Bool=true,
    local_search::Bool=true,
    time_limit::Real=60.0,
    max_iter::Int=500_000,
    rng::Random.AbstractRNG=Random.default_rng(),
    show_progress::Bool=true,
)
    if !isnothing(start)
        solution_state = _start_state(start, instance)
        is_feasible(solution_state, instance; verbose=true) || throw(
            ArgumentError(
                "the start solution is infeasible on instance (see the warnings above)."
            ),
        )
        if local_search && bundle_count(instance) > 0
            local_search!(solution_state, instance; time_limit, max_iter, rng)
        end
        return solution_state
    end

    if !filtering
        solution_state = mix_greedy_heuristic(instance; show_progress)
        if local_search
            local_search!(solution_state, instance; time_limit, max_iter, rng)
        end
        return solution_state
    end

    (; solution_state, sub_instance, filtering_state) = solve_filtered(
        instance; show_progress
    )
    if local_search && bundle_count(sub_instance) > 0
        local_search!(solution_state, sub_instance; time_limit, max_iter, rng)
    end
    return merge_solutions(filtering_state, solution_state, instance, sub_instance)
end

"""
$TYPEDSIGNATURES

Solve `instance` and return a feasible [`Solution`](@ref) on its input arcs and commodities.
This is the recommended way to solve an instance.
It is `Solution(solve_state(instance; kwargs...), instance)`, see [`solve_state`](@ref) for the pipeline and the keywords.

Pass `start` (a [`Solution`](@ref) or a [`SolutionState`](@ref)) to continue from an existing plan, for example an edited one.
Filtering and construction are skipped and `filtering` is ignored.
The cost of the result is at most the cost of the start converted by `SolutionState(start, instance)`.

Throws `ArgumentError` if no feasible construction is found, if the merged solution is infeasible, or if `start` is unrepresentable or infeasible on `instance`.
"""
function solve(
    instance::Instance;
    start::Union{Nothing,Solution,SolutionState}=nothing,
    filtering::Bool=true,
    local_search::Bool=true,
    time_limit::Real=60.0,
    max_iter::Int=500_000,
    rng::Random.AbstractRNG=Random.default_rng(),
    show_progress::Bool=true,
)
    solution_state = solve_state(
        instance; start, filtering, local_search, time_limit, max_iter, rng, show_progress
    )
    return Solution(solution_state, instance)
end
