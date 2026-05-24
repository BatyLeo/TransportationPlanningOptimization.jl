"""
$TYPEDSIGNATURES

Run the STP initial-solution pipeline up to (but not including) local search:

1. Run [`lower_bound_filtering`](@ref) on `instance`, pre-routing trivial bundles.
2. Build the sub-instance of non-trivial bundles via
   [`extract_filtered_instance`](@ref).
3. Call [`mix_greedy_and_lower_bound`](@ref) on the sub-instance.
4. Call [`choose_best_feasible`](@ref) over the three candidate solutions.

Returns `(; solution, sub_instance)`. The chosen `solution` lives on
`sub_instance`, not on the original `instance`. The caller is expected to run
[`local_search!`](@ref) on the pair next. To get a full-instance solution
afterwards, merge the result back with the filtering solution via
[`merge_solutions`](@ref).
"""
function solve_filtered(instance::Instance)
    filtering_sol = lower_bound_filtering(instance)
    sub_instance = extract_filtered_instance(instance, filtering_sol)
    candidates_tuple = mix_greedy_and_lower_bound(sub_instance)
    candidates = [
        candidates_tuple.mixed, candidates_tuple.greedy, candidates_tuple.lower_bound
    ]
    chosen = choose_best_feasible(candidates, sub_instance)
    return (; solution=chosen, sub_instance)
end
