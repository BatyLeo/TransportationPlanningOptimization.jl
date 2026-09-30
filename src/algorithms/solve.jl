"""
$TYPEDSIGNATURES

Run the initial-solution pipeline up to (but not including) local search:

1. Run [`lower_bound_filtering`](@ref) on `instance`, pre-routing trivial bundles.
2. Build the sub-instance of non-trivial bundles via
   [`extract_filtered_instance`](@ref).
3. Call [`mix_greedy_and_lower_bound`](@ref) on the sub-instance, starting
   from a solution pre-loaded (via [`preload_filtered_bundles`](@ref)) with
   the capacity and cost already claimed by the filtered-out bundles.
4. Call [`choose_best_feasible`](@ref) over the three candidate solutions.

Returns `(; solution, sub_instance)`. The chosen `solution` lives on
`sub_instance`, not on the original `instance`. The caller is expected to run
[`local_search!`](@ref) on the pair next. To get a full-instance solution
afterwards, merge the result back with the filtering solution via
[`merge_solutions`](@ref).

Because `solution` is pre-loaded with the reserved load of every filtered
bundle whose direct arc is still in `sub_instance`, `cost(result.solution)`
is neither the sub-instance cost nor the full-instance cost: it is the
sub-instance cost plus that partial reservation. The full-instance cost is
`cost(merge_solutions(filtering_sol, result.solution, instance, sub_instance))`.

Set `show_progress=false` to hide the progress bars.
"""
function solve_filtered(instance::Instance; show_progress::Bool=true)
    filtering_sol = lower_bound_filtering(instance; show_progress)
    sub_instance = extract_filtered_instance(instance, filtering_sol)
    start = preload_filtered_bundles(filtering_sol, instance, sub_instance)
    candidates_tuple = mix_greedy_and_lower_bound(sub_instance; start, show_progress)
    candidates = [
        candidates_tuple.mixed, candidates_tuple.greedy, candidates_tuple.lower_bound
    ]
    chosen = choose_best_feasible(candidates, sub_instance)
    return (; solution=chosen, sub_instance)
end
