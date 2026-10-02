using Test
using TransportationPlanningOptimization
using Dates

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "snapshot_solution creates independent copy" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    original_cost = cost(sol)

    snap = snapshot_solution(sol, instance)
    @test cost(snap) ≈ original_cost

    # Mutate the original solution
    local_search!(sol, instance; time_limit=2.0)

    # Snapshot must be unaffected
    @test cost(snap) ≈ original_cost
    @test cost(sol) != cost(snap) || cost(sol) ≈ original_cost  # LS may or may not improve
end

@testset "restore_solution! restores to snapshot state" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    original_cost = cost(sol)
    original_paths = deepcopy(sol.bundle_paths)

    snap = snapshot_solution(sol, instance)

    # Mutate via local search
    local_search!(sol, instance; time_limit=2.0)
    @test cost(sol) <= original_cost + 1e-6  # should not degrade

    # Restore
    restore_solution!(sol, snap, instance)
    @test cost(sol) ≈ original_cost atol = 1e-6
    @test sol.bundle_paths == original_paths
    @test is_feasible(sol, instance)
end

@testset "restore then re-run local search" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    snap = snapshot_solution(sol, instance)

    local_search!(sol, instance; time_limit=2.0)
    restore_solution!(sol, snap, instance)

    # Solution must still be usable after restore
    local_search!(sol, instance; time_limit=2.0)
    @test is_feasible(sol, instance)
end

slots(a::TPO.SingleAssignment) = [a]
slots(a::TPO.MultiAssignment) = a.per_mode

function same_state(sol, sol0)
    ok =
        sol.bundle_paths == sol0.bundle_paths &&
        keys(sol.assignments) == keys(sol0.assignments)
    for (edge, a) in sol.assignments,
        (s, s0) in zip(slots(a), slots(sol0.assignments[edge]))

        for f in fieldnames(TPO.SingleAssignment)
            f === :bins && continue
            ok &= getfield(s, f) == getfield(s0, f)
        end
        ok &=
            [(bin.commodities, bin.remaining_capacity) for bin in s.bins] == [(bin.commodities, bin.remaining_capacity) for bin in s0.bins]
    end
    return ok
end

# Shortest path of bundle `b` once the arcs of its current path are forbidden.
function alternative_path(sol, instance, b)
    ttg = instance.travel_time_graph
    old = sol.bundle_paths[b]
    TPO.update_bundle_cost_matrix!(sol, instance, b)
    for k in 1:(length(old) - 1)
        ttg.cost_matrix[old[k], old[k + 1]] = Inf
    end
    path = TPO.bundle_shortest_path(instance, ttg.origin_codes[b], ttg.destination_codes[b])
    isempty(path) || TPO._remove_shortcuts_from_path!(path, ttg)
    return path
end

@testset "rollback skipping snapshotted edges equals remove-then-restore" begin
    instance = TestFixtures.small_instance()
    sol0 = TestFixtures.small_greedy()
    # first bundle whose alternative path differs and touches an edge outside its snapshot
    b, new_path = 0, Int[]
    for i in eachindex(sol0.bundle_paths)
        isempty(sol0.bundle_paths[i]) && continue
        p = alternative_path(deepcopy(sol0), instance, i)
        (isempty(p) || p == sol0.bundle_paths[i]) && continue
        snaps = TPO._snapshot_path_assignments(sol0, instance, i)
        outside = false
        TPO._foreach_path_edge(instance, instance.bundles[i], p) do edge, _, _
            outside |= !haskey(snaps, edge)
            return 0.0
        end
        if outside
            b, new_path = i, p
            break
        end
    end
    @test b != 0
    old_path = copy(sol0.bundle_paths[b])

    function move!(sol)
        snapshots = TPO._snapshot_path_assignments(sol, instance, b)
        TPO.remove_bundle_path!(sol, instance, b)
        TPO.add_bundle_path!(sol, instance, b, new_path)
        return snapshots
    end
    sol_old = deepcopy(sol0)
    snapshots = move!(sol_old)
    TPO.remove_bundle_path!(sol_old, instance, b)
    TPO._restore_path_assignments!(sol_old, b, old_path, snapshots)

    sol_new = deepcopy(sol0)
    snapshots = move!(sol_new)
    TPO._rollback_bundle!(sol_new, instance, b, old_path, snapshots)
    @test same_state(sol_new, sol_old)

    # Two bundles: the second one is re-added along its old path
    b2 = findfirst(
        i -> i != b && !isempty(sol0.bundle_paths[i]), eachindex(sol0.bundle_paths)
    )
    idxs = [b, b2]
    old_paths = [copy(sol0.bundle_paths[i]) for i in idxs]
    function multi_move!(sol)
        snapshots = TPO._snapshot_multi_bundle_assignments(sol, instance, idxs)
        foreach(i -> TPO.remove_bundle_path!(sol, instance, i), idxs)
        TPO.add_bundle_path!(sol, instance, b, new_path)
        TPO.add_bundle_path!(sol, instance, b2, old_paths[2])
        return snapshots
    end
    sol_old = deepcopy(sol0)
    snapshots = multi_move!(sol_old)
    foreach(i -> TPO.remove_bundle_path!(sol_old, instance, i), idxs)
    TPO._restore_multi_bundle_assignments!(sol_old, idxs, old_paths, snapshots)

    sol_new = deepcopy(sol0)
    snapshots = multi_move!(sol_new)
    foreach(i -> TPO._remove_unsnapshotted_path!(sol_new, instance, i, snapshots), idxs)
    TPO._restore_multi_bundle_assignments!(sol_new, idxs, old_paths, snapshots)
    @test same_state(sol_new, sol_old)
end
