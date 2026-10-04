"""
$TYPEDSIGNATURES

Building block of [`solve`](@ref) for advanced workflows: run the filtered
initial-solution pipeline up to (but not including) local search.

1. Run [`lower_bound_filtering`](@ref) on `instance`, pre-routing trivial bundles.
2. Build the sub-instance of non-trivial bundles via
   [`extract_filtered_instance`](@ref).
3. Call [`mix_greedy_heuristic`](@ref) on the sub-instance, starting from a
   solution pre-loaded (via [`preload_filtered_bundles`](@ref)) with the
   capacity and cost already claimed by the filtered-out bundles.

Returns `(; solution, sub_instance, filtering_solution)`. The `solution` lives
on `sub_instance`, not on the original `instance`, and `filtering_solution` is
the full-instance solution of step 1. Improve `solution` on `sub_instance` with
[`local_search!`](@ref) or [`iterated_local_search!`](@ref), then get the
full-instance solution with
`merge_solutions(result.filtering_solution, result.solution, instance, result.sub_instance)`.

Because `solution` is pre-loaded with the reserved load of every filtered
bundle whose direct arc is still in `sub_instance`, `cost(result.solution)`
is neither the sub-instance cost nor the full-instance cost. Only the merged
solution has the full-instance cost.

Set `show_progress=false` to hide the progress bars.
"""
function solve_filtered(instance::Instance; show_progress::Bool=true)
    filtering_solution = lower_bound_filtering(instance; show_progress)
    sub_instance = extract_filtered_instance(instance, filtering_solution)
    start = preload_filtered_bundles(filtering_solution, instance, sub_instance)
    solution = mix_greedy_heuristic(sub_instance; start, show_progress)
    return (; solution, sub_instance, filtering_solution)
end

"""
$TYPEDSIGNATURES

Solve `instance` and return a feasible [`SolutionState`](@ref) on it. This is the
recommended way to solve an instance.

With `filtering=true` (default):

1. [`lower_bound_filtering`](@ref) fixes the bundles whose best path is the
   direct arc.
2. The remaining bundles form a sub-instance, solved by
   [`mix_greedy_heuristic`](@ref) from a start holding the load of the fixed
   bundles (see [`solve_filtered`](@ref)).
3. If `local_search=true`, [`local_search!`](@ref) improves the sub-instance
   solution.
4. [`merge_solutions`](@ref) brings the result back to the full instance.

With `filtering=false`, construction ([`mix_greedy_heuristic`](@ref)) and local
search run directly on the full instance. This is only reasonable on small
instances: construction on the full instance is much slower on large ones,
because its cost scales with the number of unit commodities times the number
of bundle arcs (and so is that of [`greedy_heuristic`](@ref)).

`time_limit` (seconds), `max_iter` and `rng` only apply to local search, so
`time_limit` does not cover construction. Local search also stops after 15000
consecutive non-improving iterations (the [`local_search!`](@ref) default), so
it can return well before `time_limit`. All steps use [`CheapestMode`](@ref).
Set `show_progress=false` to hide the progress bars.

Throws `ArgumentError` if no feasible construction is found or if the merged
solution is infeasible.

For advanced workflows (for example [`iterated_local_search!`](@ref) on the
sub-instance), use [`solve_filtered`](@ref) and the building blocks directly.
"""
function solve(
    instance::Instance;
    filtering::Bool=true,
    local_search::Bool=true,
    time_limit::Real=60.0,
    max_iter::Int=500_000,
    rng::Random.AbstractRNG=Random.default_rng(),
    show_progress::Bool=true,
)
    if !filtering
        solution = mix_greedy_heuristic(instance; show_progress)
        if local_search
            local_search!(solution, instance; time_limit, max_iter, rng)
        end
        return solution
    end

    (; solution, sub_instance, filtering_solution) = solve_filtered(instance; show_progress)
    if local_search && bundle_count(sub_instance) > 0
        local_search!(solution, sub_instance; time_limit, max_iter, rng)
    end
    return merge_solutions(filtering_solution, solution, instance, sub_instance)
end
