"""
$TYPEDSIGNATURES

Run Iterated Local Search on `sol`.

Cycles through `perturbations` round-robin, accumulating changes until
thresholds trigger a local search phase. Tracks the best solution found
and restores it at the end.

The optional `cost_update!` callback is called after every local search
phase (regardless of whether a new best was found). It receives
`(instance, sol)` and may mutate `instance.travel_time_graph.cost_scaling`
or other mutable state. Slope scaling is one implementation.

The optional `on_improvement` callback is called each time a new best
solution is found. It receives `(sol, best_cost, elapsed_seconds)`.
"""
function iterated_local_search!(
    sol::Solution,
    instance::Instance,
    perturbations::Vector{<:AbstractPerturbation};
    config::ILSConfig=ILSConfig(),
    cost_update!::Union{Nothing,Function}=nothing,
    on_improvement::Union{Nothing,Function}=nothing,
    mode_selector::AbstractModeSelector=CheapestMode(),
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=true,
)
    isempty(perturbations) && throw(ArgumentError("perturbations must be non-empty"))

    start_time = time()
    start_cost = cost(sol)
    initial = snapshot_solution(sol, instance)
    best = snapshot_solution(sol, instance)
    best_cost = start_cost
    cost_history = Tuple{Float64,Float64}[(0.0, start_cost)]

    if cost_update! !== nothing
        cost_update!(instance, sol)
    end

    change_threshold = max(
        1, round(Int, config.change_threshold_ratio * bundle_count(instance))
    )
    cost_threshold = config.cost_threshold_ratio * best_cost

    no_change = 0
    no_improv = 0
    iteration = 0
    perturbation_index = 0

    while (time() - start_time) < config.time_limit
        if no_change >= config.max_no_change || no_improv >= config.max_no_improv
            verbose && @info "ILS converged" no_change no_improv iteration
            break
        end

        perturbation_index = (perturbation_index % length(perturbations)) + 1
        perturbation = perturbations[perturbation_index]

        changed = 0
        cost_added = 0.0
        perturbation_start = time()

        while (time() - perturbation_start) < config.perturbation_time_limit
            improv, n = perturbate!(sol, instance, perturbation; rng, verbose)
            changed += n
            cost_added += improv
            if changed >= change_threshold || cost_added >= cost_threshold
                break
            end
            # If a single perturbation returned 0 changes, don't loop
            n == 0 && break
        end

        if changed == 0
            no_change += 1
            continue
        else
            no_change = 0
        end

        local_search!(sol, instance, mode_selector; time_limit=config.ls_time_limit, rng)

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
            if on_improvement !== nothing
                on_improvement(sol, best_cost, elapsed)
            end
        else
            no_improv += 1
        end

        if cost_update! !== nothing
            cost_update!(instance, sol)
        end

        iteration += 1
    end

    restore_solution!(sol, best, instance)
    local_search!(sol, instance, mode_selector; time_limit=config.ls_time_limit, rng)

    final_cost = cost(sol)
    if final_cost < best_cost
        best_cost = final_cost
        elapsed = time() - start_time
        push!(cost_history, (elapsed, best_cost))
        if on_improvement !== nothing
            on_improvement(sol, best_cost, elapsed)
        end
    end

    if best_cost > start_cost
        restore_solution!(sol, initial, instance)
        time_elapsed = time() - start_time
        verbose && @info "ILS reverted (no improvement)" time_elapsed
        return ILSResult(0.0, start_cost, iteration, time_elapsed, cost_history)
    end

    improvement = start_cost - best_cost
    time_elapsed = time() - start_time
    verbose && @info "ILS complete" improvement best_cost time_elapsed iteration
    return ILSResult(improvement, best_cost, iteration, time_elapsed, cost_history)
end
