# Per-step profiling of the local search inner loop.
#
# Instruments the same code path as `_try_reinsert_bundle!` (with snapshot/revert)
# to time each substep:
#   snapshot, remove_path, update_cost, dijkstra, restore/add+rollback
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
    snapshot_ns::Vector{UInt64}
    remove_ns::Vector{UInt64}
    update_cost_ns::Vector{UInt64}
    dijkstra_ns::Vector{UInt64}
    restore_or_add_ns::Vector{UInt64}
    total_ns::Vector{UInt64}
    outcome::Vector{Symbol}  # :same_path, :improved, :rollback, :no_path
end

function StepTimings(n::Int)
    return StepTimings(
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{UInt64}(undef, n),
        Vector{Symbol}(undef, n),
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
    n_bundles = length(instance.bundles)

    for i in 1:n_iters
        bundle_idx = rand(rng, 1:n_bundles)
        while isempty(sol.bundle_paths[bundle_idx])
            bundle_idx = rand(rng, 1:n_bundles)
        end

        t_total = time_ns()

        # Deferred removal: snapshot and remove are 0 for same-path iterations
        timings.snapshot_ns[i] = UInt64(0)
        timings.remove_ns[i] = UInt64(0)

        old_path = copy(sol.bundle_paths[bundle_idx])

        # Step 1: update_cost_matrix (no prior removal)
        t0 = time_ns()
        TPO.update_bundle_cost_matrix!(
            sol, instance, bundle_idx, mode_selector; packing=:frozen
        )
        t1 = time_ns()
        timings.update_cost_ns[i] = t1 - t0

        # Step 2: dijkstra + trace
        t0 = time_ns()
        origin = ttg.origin_codes[bundle_idx]
        dest = ttg.destination_codes[bundle_idx]
        parents, _ = TPO.bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix)
        new_path = TPO.trace_path(parents, origin, dest)
        t1 = time_ns()
        timings.dijkstra_ns[i] = t1 - t0

        # Step 3: same-path or deferred remove+add
        t0 = time_ns()
        if isempty(new_path)
            timings.outcome[i] = :no_path
        else
            TPO._remove_shortcuts_from_path!(new_path, ttg)
            if new_path == old_path
                timings.outcome[i] = :same_path
            else
                # Deferred: snapshot + remove + add + accept/reject
                t_snap = time_ns()
                snapshots = TPO._snapshot_path_assignments(sol, instance, bundle_idx)
                t_snap_end = time_ns()
                timings.snapshot_ns[i] = t_snap_end - t_snap

                t_rem = time_ns()
                cost_removed = TPO.remove_bundle_path!(sol, instance, bundle_idx)
                t_rem_end = time_ns()
                timings.remove_ns[i] = t_rem_end - t_rem

                cost_added = TPO.add_bundle_path!(
                    sol, instance, bundle_idx, new_path; mode_selector, packing=:ffd_union
                )
                net_delta = cost_added + cost_removed
                if net_delta < -1e-6
                    timings.outcome[i] = :improved
                else
                    TPO.remove_bundle_path!(sol, instance, bundle_idx)
                    TPO._restore_path_assignments!(sol, bundle_idx, old_path, snapshots)
                    timings.outcome[i] = :rollback
                end
            end
        end
        t1 = time_ns()
        timings.restore_or_add_ns[i] = t1 - t0

        timings.total_ns[i] = t1 - t_total
    end
    return timings
end

function print_timing_report(name::String, timings::StepTimings, n_iters::Int)
    to_ms(v) = Float64.(v) ./ 1e6

    snapshot_ms = to_ms(timings.snapshot_ns)
    remove_ms = to_ms(timings.remove_ns)
    update_ms = to_ms(timings.update_cost_ns)
    dijkstra_ms = to_ms(timings.dijkstra_ns)
    restore_ms = to_ms(timings.restore_or_add_ns)
    total_ms = to_ms(timings.total_ns)

    med(v) = sort(v)[length(v) ÷ 2 + 1]
    avg(v) = sum(v) / length(v)

    total_wall_s = sum(total_ms) / 1000
    iter_per_s = n_iters / total_wall_s
    n_same = count(==(Symbol("same_path")), timings.outcome)
    n_improved = count(==(Symbol("improved")), timings.outcome)
    n_rollback = count(==(Symbol("rollback")), timings.outcome)
    n_nopath = count(==(Symbol("no_path")), timings.outcome)

    println()
    println("="^78)
    @printf("  Instance: %s  |  %d iterations  |  %.1f iter/s\n", name, n_iters, iter_per_s)
    @printf(
        "  Same path: %d (%.1f%%)  |  Improved: %d (%.1f%%)  |  Rollback: %d (%.1f%%)  |  No path: %d\n",
        n_same,
        100.0 * n_same / n_iters,
        n_improved,
        100.0 * n_improved / n_iters,
        n_rollback,
        100.0 * n_rollback / n_iters,
        n_nopath,
    )
    println("="^78)
    println()

    total_sum = sum(total_ms)
    steps = [
        ("snapshot", snapshot_ms),
        ("remove_path", remove_ms),
        ("update_cost", update_ms),
        ("dijkstra", dijkstra_ms),
        ("restore/add", restore_ms),
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

    # Per-outcome breakdown
    println()
    println("  Per-outcome median (ms):")
    @printf(
        "  %-16s %10s %10s %10s %10s %10s %10s\n",
        "Outcome",
        "snapshot",
        "remove",
        "update",
        "dijkstra",
        "restore/add",
        "total"
    )
    @printf(
        "  %-16s %10s %10s %10s %10s %10s %10s\n",
        "-"^16,
        "-"^10,
        "-"^10,
        "-"^10,
        "-"^10,
        "-"^10,
        "-"^10
    )
    for (sym, label) in [
        (:same_path, "same_path"),
        (:improved, "improved"),
        (:rollback, "rollback"),
        (:no_path, "no_path"),
    ]
        mask = timings.outcome .== sym
        n = count(mask)
        n == 0 && continue
        m(v) = sort(v[mask])[count(mask) ÷ 2 + 1]
        @printf(
            "  %-16s %10.3f %10.3f %10.3f %10.3f %10.3f %10.3f  (n=%d)\n",
            label,
            m(to_ms(timings.snapshot_ns)),
            m(to_ms(timings.remove_ns)),
            m(to_ms(timings.update_cost_ns)),
            m(to_ms(timings.dijkstra_ns)),
            m(to_ms(timings.restore_or_add_ns)),
            m(to_ms(timings.total_ns)),
            n
        )
    end
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
