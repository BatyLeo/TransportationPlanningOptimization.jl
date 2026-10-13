"""
$TYPEDEF

Configuration for [`iterated_local_search!`](@ref).

All time limits are in seconds. Ratio parameters are fractions (0.0 to 1.0)
applied to the number of bundles or the current best cost.
The main loop has `time_limit - final_ls_time_limit` seconds, and each perturbation call
also gets at most the time left in it.
`final_ls_time_limit` is `min(300, time_limit / 6)` by default
and cannot exceed `time_limit`.

# Fields
$TYPEDFIELDS
"""
struct ILSConfig
    "Wall-clock time limit of the whole call, the final local search included"
    time_limit::Float64
    "Time limit per perturbation phase"
    perturbation_time_limit::Float64
    "Time limit per local search phase inside the main loop"
    ls_time_limit::Float64
    "Time reserved at the end of `time_limit` for the final local search"
    final_ls_time_limit::Float64
    "Fraction of bundles that must change to trigger local search"
    change_threshold_ratio::Float64
    "Fraction of the best cost that the cost increase must reach to end a perturbation"
    cost_threshold_ratio::Float64
    "Stop after this many consecutive perturbation rounds with zero changes"
    max_no_change::Int
    "Stop after this many consecutive LS rounds without improving the best"
    max_no_improv::Int
end

function ILSConfig(;
    time_limit::Real=1800.0,
    perturbation_time_limit::Real=180.0,
    ls_time_limit::Real=300.0,
    final_ls_time_limit::Real=min(300.0, time_limit / 6),
    change_threshold_ratio::Real=0.15,
    cost_threshold_ratio::Real=0.0175,
    max_no_change::Int=3,
    max_no_improv::Int=3,
)
    time_limit >= 0 || throw(ArgumentError("time_limit must be nonnegative"))
    perturbation_time_limit > 0 ||
        throw(ArgumentError("perturbation_time_limit must be positive"))
    ls_time_limit >= 0 || throw(ArgumentError("ls_time_limit must be nonnegative"))
    isfinite(final_ls_time_limit) ||
        throw(ArgumentError("final_ls_time_limit must be finite, got $final_ls_time_limit"))
    final_ls_time_limit >= 0 || throw(
        ArgumentError("final_ls_time_limit must be nonnegative, got $final_ls_time_limit"),
    )
    final_ls_time_limit <= time_limit || throw(
        ArgumentError(
            "final_ls_time_limit ($final_ls_time_limit) must not exceed time_limit ($time_limit)",
        ),
    )
    return ILSConfig(
        Float64(time_limit),
        Float64(perturbation_time_limit),
        Float64(ls_time_limit),
        Float64(final_ls_time_limit),
        Float64(change_threshold_ratio),
        Float64(cost_threshold_ratio),
        max_no_change,
        max_no_improv,
    )
end

"""
$TYPEDEF

Result of [`iterated_local_search!`](@ref).

# Fields
$TYPEDFIELDS
"""
struct ILSResult
    "Total cost improvement (non-negative)"
    improvement::Float64
    "Cost of the best solution found"
    best_cost::Float64
    "Number of ILS iterations completed"
    iterations::Int
    "Wall-clock seconds elapsed"
    time_elapsed::Float64
    "Vector of (elapsed_seconds, cost) at each improvement"
    cost_history::Vector{Tuple{Float64,Float64}}
end
