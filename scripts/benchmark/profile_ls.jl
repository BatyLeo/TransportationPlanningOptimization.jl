# Per-step profiling of the local search inner loop.
#
# Instruments _try_reinsert_bundle! to time each substep:
#   remove_path, update_cost, dijkstra, add/rollback
#
# Also runs Julia's Profile module for a flat sample-based breakdown.
#
# Run with:
#   julia --project=scripts scripts/benchmark/profile_ls.jl [instance_name] [n_iters]
#
# Defaults: medium, 500 iterations

using Random
using Profile
using Printf
using Dates
using SparseArrays

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")

function load_instance(name::String)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")
    (; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
    return TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

function init_solution(instance)
    filtering_sol = TPO.lower_bound_filtering(instance)
    sub = TPO.extract_filtered_instance(instance, filtering_sol)
    candidates = TPO.mix_greedy_and_lower_bound(sub)
    chosen = TPO.choose_best_feasible(
        [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
    )
    return sub, chosen
end

struct StepTimings
    remove_ns::Vector{UInt64}
    update_cost_ns::Vector{UInt64}
    dijkstra_ns::Vector{UInt64}
    add_rollback_ns::Vector{UInt64}
    total_ns::Vector{UInt64}
    was_improvement::Vector{Bool}
    was_same_path::Vector{Bool}
end

function StepTimings(n::Int)
    return StepTimings(
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{Bool}(undef, n),
        Vector{Bool}(undef, n),
    )
end

function profile_reinsert_steps!(
    sol::TPO.Solution,
    instance::TPO.Instance,
    n_iters::Int;
    rng::Random.AbstractRNG=Random.MersenneTwister(42),
)
    timings = StepTimings(n_iters)
    ttg = instance.travel_time_graph
    mode_selector = TPO.CheapestMode()
    buffer = TPO.BinPackingBuffer()
    n_bundles = length(instance.bundles)

    for i in 1:n_iters
        bundle_idx = rand(rng, 1:n_bundles)
        while isempty(sol.bundle_paths[bundle_idx])
            bundle_idx = rand(rng, 1:n_bundles)
        end

        old_path = copy(sol.bundle_paths[bundle_idx])
        t_total = time_ns()

        # Step 1: remove_path
        t0 = time_ns()
        cost_removed = TPO.remove_bundle_path!(sol, instance, bundle_idx)
        t1 = time_ns()
        timings.remove_ns[i] = t1 - t0

        # Step 2: update_cost_matrix
        t0 = time_ns()
        TPO.update_bundle_cost_matrix!(
            sol, instance, bundle_idx, mode_selector; buffer, packing=:frozen
        )
        t1 = time_ns()
        timings.update_cost_ns[i] = t1 - t0

        # Step 3: dijkstra
        origin = ttg.origin_codes[bundle_idx]
        dest = ttg.destination_codes[bundle_idx]
        t0 = time_ns()
        parents, _ = TPO.bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix)
        t1 = time_ns()
        timings.dijkstra_ns[i] = t1 - t0

        new_path = TPO.trace_path(parents, origin, dest)

        # Step 4: add (or rollback)
        t0 = time_ns()
        if isempty(new_path)
            TPO.add_bundle_path!(sol, instance, bundle_idx, old_path; mode_selector)
            timings.was_improvement[i] = false
            timings.was_same_path[i] = false
        else
            cost_added = TPO.add_bundle_path!(
                sol, instance, bundle_idx, new_path; mode_selector
            )
            net_delta = cost_added + cost_removed
            if net_delta < -1e-6
                timings.was_improvement[i] = true
                timings.was_same_path[i] = false
            elseif new_path == old_path
                timings.was_improvement[i] = false
                timings.was_same_path[i] = true
            else
                TPO.remove_bundle_path!(sol, instance, bundle_idx)
                TPO.add_bundle_path!(sol, instance, bundle_idx, old_path; mode_selector)
                timings.was_improvement[i] = false
                timings.was_same_path[i] = false
            end
        end
        t1 = time_ns()
        timings.add_rollback_ns[i] = t1 - t0

        timings.total_ns[i] = t1 - t_total
    end
    return timings
end

function print_timing_report(name::String, timings::StepTimings, n_iters::Int)
    to_ms(v) = Float64.(v) ./ 1e6

    remove_ms = to_ms(timings.remove_ns)
    update_ms = to_ms(timings.update_cost_ns)
    dijkstra_ms = to_ms(timings.dijkstra_ns)
    add_ms = to_ms(timings.add_rollback_ns)
    total_ms = to_ms(timings.total_ns)

    med(v) = sort(v)[length(v) ÷ 2 + 1]
    avg(v) = sum(v) / length(v)

    total_wall_s = sum(total_ms) / 1000
    iter_per_s = n_iters / total_wall_s
    n_improved = count(timings.was_improvement)
    n_same = count(timings.was_same_path)

    println()
    println("="^70)
    @printf("  Instance: %s  |  %d iterations  |  %.1f iter/s\n", name, n_iters, iter_per_s)
    @printf(
        "  Improved: %d (%.1f%%)  |  Same path: %d (%.1f%%)\n",
        n_improved,
        100.0 * n_improved / n_iters,
        n_same,
        100.0 * n_same / n_iters
    )
    println("="^70)
    println()

    total_sum = sum(total_ms)
    steps = [
        ("remove_path", remove_ms),
        ("update_cost", update_ms),
        ("dijkstra", dijkstra_ms),
        ("add+rollback", add_ms),
    ]

    @printf(
        "  %-16s %10s %10s %10s %8s\n",
        "Step",
        "median(ms)",
        "mean(ms)",
        "sum(ms)",
        "% total"
    )
    @printf("  %-16s %10s %10s %10s %8s\n", "-"^16, "-"^10, "-"^10, "-"^10, "-"^8)
    for (label, data) in steps
        s = sum(data)
        @printf(
            "  %-16s %10.3f %10.3f %10.1f %7.1f%%\n",
            label,
            med(data),
            avg(data),
            s,
            100.0 * s / total_sum
        )
    end
    overhead = total_sum - sum(sum(d) for (_, d) in steps)
    @printf(
        "  %-16s %10s %10s %10.1f %7.1f%%\n",
        "overhead",
        "",
        "",
        overhead,
        100.0 * overhead / total_sum
    )
    @printf(
        "  %-16s %10.3f %10.3f %10.1f %7.1f%%\n",
        "TOTAL",
        med(total_ms),
        avg(total_ms),
        total_sum,
        100.0
    )
    return println()
end

function run_julia_profile!(sol, instance, n_iters; rng=Random.MersenneTwister(42))
    Profile.clear()
    @profile profile_reinsert_steps!(sol, instance, n_iters; rng)
    println("--- Julia Profile (flat, top 30) ---")
    Profile.print(; format=:flat, mincount=10, sortedby=:count, maxdepth=120)
    return println()
end

function main()
    instance_name = length(ARGS) >= 1 ? ARGS[1] : "medium"
    n_iters = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 500

    println("Loading instance: $instance_name ...")
    instance = load_instance(instance_name)
    println("  Bundles: $(length(instance.bundles))")
    mean_arcs = round(
        Int,
        sum(length(a) for a in instance.travel_time_graph.bundle_arcs) /
        length(instance.bundles),
    )
    println("  Mean bundle arcs: $mean_arcs")

    println("Initializing solution (filter + mix G+LB) ...")
    sub, sol = init_solution(instance)
    println("  Filtered bundles: $(length(sub.bundles))")
    println("  Init cost: $(round(TPO.cost(sol); digits=1))")

    # Warmup (5 iters, discard)
    println("Warmup ...")
    _ = profile_reinsert_steps!(sol, sub, 5; rng=Random.MersenneTwister(1))

    # Timed run
    println("Profiling $n_iters iterations ...")
    timings = profile_reinsert_steps!(sol, sub, n_iters)
    print_timing_report(instance_name, timings, n_iters)

    # Julia sample-based profile (separate short run to keep samples clean)
    println("Running Julia Profile ($n_iters iterations) ...")
    run_julia_profile!(sol, sub, n_iters)

    return println("Final cost: $(round(TPO.cost(sol); digits=1))")
end

main()
