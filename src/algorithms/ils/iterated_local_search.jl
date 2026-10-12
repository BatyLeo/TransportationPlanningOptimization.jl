"""
$TYPEDSIGNATURES

Run Iterated Local Search on `sol`.

Cycles through `perturbations` round-robin. Each round repeats the perturbation until the accumulated
number of changed bundles reaches the change threshold, or the accumulated cost
increase reaches the cost threshold, or the perturbation time limit is hit.
The accumulators are only reset after a local search phase.
A round with no accumulated change counts toward `max_no_change`.
Local search runs only once the change threshold is reached, followed by a second
local search if the result is within 0.025% of the best cost. A better result becomes
the new best, otherwise the round counts toward `max_no_improv`.
At the end the best solution is restored and polished by a final local search.

The optional `cost_update!` callback is called once before the loop, then after every
local search phase. It receives `(instance, sol)` and may mutate
`instance.travel_time_graph.cost_scaling` or other mutable state.
Slope scaling is one implementation: it only shapes the MILP perturbation objectives.
The cost scaling factors of the travel time graph are always emptied when the call
returns, also when it throws, including factors set by the caller.

The optional `on_improvement` callback is called each time a new best
solution is found. It receives `(sol, best_cost, elapsed_seconds)`.
"""
function iterated_local_search!(
    sol::SolutionState,
    instance::Instance,
    perturbations::Vector{<:AbstractPerturbation};
    config::ILSConfig=ILSConfig(),
    cost_update!::Union{Nothing,Function}=nothing,
    on_improvement::Union{Nothing,Function}=nothing,
    mode_selector::AbstractModeSelector=CheapestMode(),
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=true,
)
    try
        isempty(perturbations) && throw(ArgumentError("perturbations must be non-empty"))
        start_time = time()
        start_cost = cost(sol)
        best = snapshot_solution(sol, instance)
        best_cost = start_cost
        cost_history = Tuple{Float64,Float64}[(0.0, start_cost)]

        if !isnothing(cost_update!)
            cost_update!(instance, sol)
        end

        change_threshold = max(
            1, round(Int, config.change_threshold_ratio * bundle_count(instance))
        )
        cost_threshold = config.cost_threshold_ratio * best_cost

        changed = 0
        accumulated_increase = 0.0
        no_change = 0
        no_improv = 0
        iteration = 0
        perturbation_index = 0

        while (time() - start_time) < config.time_limit
            perturbation_index = (perturbation_index % length(perturbations)) + 1
            perturbation = perturbations[perturbation_index]

            perturbation_start = time()
            while (time() - perturbation_start) < config.perturbation_time_limit
                cost_increase, n = perturbate!(sol, instance, perturbation; rng, verbose)
                changed += n
                accumulated_increase += cost_increase
                if changed >= change_threshold || accumulated_increase >= cost_threshold
                    break
                end
            end

            if changed == 0
                no_change += 1
            else
                no_change = 0
            end

            if changed >= change_threshold
                local_search!(
                    sol, instance, mode_selector; time_limit=config.ls_time_limit, rng
                )
                changed = 0
                accumulated_increase = 0.0

                current_cost = cost(sol)
                if current_cost > best_cost && current_cost < 1.00025 * best_cost
                    local_search!(
                        sol, instance, mode_selector; time_limit=config.ls_time_limit, rng
                    )
                    current_cost = cost(sol)
                end

                if current_cost < best_cost
                    best = snapshot_solution(sol, instance)
                    best_cost = current_cost
                    elapsed = time() - start_time
                    push!(cost_history, (elapsed, best_cost))
                    cost_threshold = config.cost_threshold_ratio * best_cost
                    no_improv = 0
                    verbose && @info "New best solution" best_cost elapsed
                    if !isnothing(on_improvement)
                        on_improvement(sol, best_cost, elapsed)
                    end
                else
                    no_improv += 1
                end

                if !isnothing(cost_update!)
                    cost_update!(instance, sol)
                end
            end

            iteration += 1

            if no_change >= config.max_no_change || no_improv >= config.max_no_improv
                verbose && @info "ILS converged" no_change no_improv iteration
                break
            end
        end

        restore_solution!(sol, best, instance)
        local_search!(sol, instance, mode_selector; time_limit=config.ls_time_limit, rng)

        final_cost = cost(sol)
        if final_cost < best_cost
            best_cost = final_cost
            elapsed = time() - start_time
            push!(cost_history, (elapsed, best_cost))
            if !isnothing(on_improvement)
                on_improvement(sol, best_cost, elapsed)
            end
        end

        improvement = start_cost - best_cost
        time_elapsed = time() - start_time
        verbose && @info "ILS complete" improvement best_cost time_elapsed iteration
        return ILSResult(improvement, best_cost, iteration, time_elapsed, cost_history)
    finally
        empty!(instance.travel_time_graph.cost_scaling)
    end
end
