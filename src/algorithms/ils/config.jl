"""
$TYPEDEF

Configuration for [`iterated_local_search!`](@ref).

All time limits are in seconds. Ratio parameters are fractions (0.0 to 1.0)
applied to the number of bundles or the current best cost.

# Fields
$TYPEDFIELDS
"""
struct ILSConfig
    "Total wall-clock time limit"
    time_limit::Float64
    "Time limit per perturbation phase"
    perturbation_time_limit::Float64
    "Time limit per local search phase"
    ls_time_limit::Float64
    "Fraction of bundles that must change to trigger local search"
    change_threshold_ratio::Float64
    "Fraction of cost change that triggers local search"
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
    change_threshold_ratio::Real=0.15,
    cost_threshold_ratio::Real=0.0175,
    max_no_change::Int=3,
    max_no_improv::Int=3,
)
    return ILSConfig(
        Float64(time_limit),
        Float64(perturbation_time_limit),
        Float64(ls_time_limit),
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
    "Total cost improvement (non-negative, 0.0 if reverted)"
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
