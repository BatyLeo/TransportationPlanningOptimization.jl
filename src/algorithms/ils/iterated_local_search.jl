"""
Shortest time in seconds left in a perturbation phase or in the loop for a call to start.
It must be at least `MIN_MILP_TIME`, so that the MILP perturbations never receive a budget
they reject at once. With a perturbation or loop limit under 2 seconds, the loop uses half
of the shorter limit instead.
"""
const MIN_CALL_TIME = 1.0

"""
$TYPEDSIGNATURES

Run Iterated Local Search on `sol`.

Cycles through `perturbations` round-robin, after dropping the ones that do not
[`supports_instance`](@ref) (logged once, an `ArgumentError` is thrown when none is left). Each round repeats the perturbation until the accumulated
number of changed bundles reaches the change threshold, or the accumulated cost
increase reaches the cost threshold, or the perturbation time limit is hit.
Each perturbation call receives the time it may use, the smaller of the time left in the
main loop and in the perturbation phase.
No call starts with less than `MIN_CALL_TIME` (1 second) left, or half of the shorter of
the perturbation limit and the main loop limit when that limit is under 2 seconds.
The accumulators are only reset after a local search phase.
A round with no accumulated change counts toward `max_no_change`.
After each perturbation phase, a solution cheaper than the best becomes the new best, so
an improvement is never lost when the change threshold is not reached.
Local search runs only once the change threshold is reached, followed by a second
local search if the result is within 0.025% of the best cost. A result better than the best
(including a best set by a perturbation phase) becomes the new best.
`max_no_improv` counts the local search phases with no new best since the previous one,
including the perturbation phases that came before it.
`config.time_limit` is the wall-clock limit of the whole call.
The main loop, with its phases, stops `config.final_ls_time_limit` before it.
`config.ls_time_limit` only limits each local search phase inside the loop.
At the end the best solution is restored and polished by a final local search of at most
`config.final_ls_time_limit`, and of at most the time left in `config.time_limit`.
It does not run when no time is left.

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
        supported = filter(p -> supports_instance(p, instance), perturbations)
        if length(supported) < length(perturbations)
            skipped = [typeof(p) for p in perturbations if !supports_instance(p, instance)]
            verbose && @info "Skipping perturbations that do not support the instance" skipped
        end
        isempty(supported) && throw(
            ArgumentError(
                "no perturbation supports this instance, the MILP perturbations do not support multimodal arcs",
            ),
        )
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
        improved_since_ls = false
        iteration = 0
        perturbation_index = 0

        loop_limit = config.time_limit - config.final_ls_time_limit
        loop_left() = loop_limit - (time() - start_time)
        # No perturbation call starts with less time than this left in the phase or in the
        # loop.
        # A short limit lowers it to half of itself, so that a first call always starts.
        min_call = min(MIN_CALL_TIME, config.perturbation_time_limit / 2, loop_limit / 2)
        # Local search within the time left in the main loop, skipped when none is left.
        function loop_local_search!()
            t = min(config.ls_time_limit, loop_left())
            t > 0 && local_search!(sol, instance, mode_selector; time_limit=t, rng)
            return nothing
        end
        # Make the current solution the new best when it is cheaper than the best.
        function record_best!(current_cost)
            current_cost < best_cost || return nothing
            best = snapshot_solution(sol, instance)
            best_cost = current_cost
            elapsed = time() - start_time
            push!(cost_history, (elapsed, best_cost))
            cost_threshold = config.cost_threshold_ratio * best_cost
            no_improv = 0
            improved_since_ls = true
            verbose && @info "New best solution" best_cost elapsed
            if !isnothing(on_improvement)
                on_improvement(sol, best_cost, elapsed)
            end
            return nothing
        end

        while loop_limit > 0 && loop_left() >= min_call
            perturbation_index = (perturbation_index % length(supported)) + 1
            perturbation = supported[perturbation_index]

            perturbation_start = time()
            while true
                call_time = min(
                    loop_left(),
                    config.perturbation_time_limit - (time() - perturbation_start),
                )
                call_time >= min_call || break
                cost_increase, n = perturbate!(
                    sol, instance, perturbation; rng, verbose, time_limit=call_time
                )
                changed += n
                accumulated_increase += cost_increase
                if changed >= change_threshold || accumulated_increase >= cost_threshold
                    break
                end
            end
            record_best!(cost(sol))

            if changed == 0
                no_change += 1
            else
                no_change = 0
            end

            if changed >= change_threshold
                loop_local_search!()
                changed = 0
                accumulated_increase = 0.0

                current_cost = cost(sol)
                if current_cost > best_cost && current_cost < 1.00025 * best_cost
                    loop_local_search!()
                    current_cost = cost(sol)
                end

                record_best!(current_cost)
                improved_since_ls || (no_improv += 1)
                improved_since_ls = false

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
        # The final local search gets the reserved time and what is left of the total
        # limit.
        final_time = min(
            config.final_ls_time_limit, config.time_limit - (time() - start_time)
        )
        final_time > 0 &&
            local_search!(sol, instance, mode_selector; time_limit=final_time, rng)

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
