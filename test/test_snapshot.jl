using Test
using TransportationPlanningOptimization
using Dates
using Random

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

    # SolutionState must still be usable after restore
    local_search!(sol, instance; time_limit=2.0)
    @test is_feasible(sol, instance)
end

using .TestFixtures: same_state

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

@testset "rollback restores the exact state, including edges the move created" begin
    instance = TestFixtures.small_instance()
    sol0 = TestFixtures.small_greedy()
    # first bundle whose alternative path differs and uses an edge without assignment
    b, new_path = 0, Int[]
    for i in eachindex(sol0.bundle_paths)
        isempty(sol0.bundle_paths[i]) && continue
        p = alternative_path(deepcopy(sol0), instance, i)
        (isempty(p) || p == sol0.bundle_paths[i]) && continue
        snaps = TPO._snapshot_path_assignments(sol0, instance, i, p)
        if any(isnothing, values(snaps))
            b, new_path = i, p
            break
        end
    end
    @test b != 0
    old_path = copy(sol0.bundle_paths[b])

    sol = deepcopy(sol0)
    snapshots = TPO._snapshot_path_assignments(sol, instance, b, old_path)
    TPO.remove_bundle_path!(sol, instance, b)
    TPO._snapshot_path_assignments(sol, instance, b, new_path; cache=snapshots, clear=false)
    TPO.add_bundle_path!(sol, instance, b, copy(new_path))
    @test !same_state(sol, sol0)
    @test length(sol.assignments) > length(sol0.assignments)
    TPO._restore_path_assignments!(sol, b, old_path, snapshots)
    @test same_state(sol, sol0)

    # Two bundles: the second one is re-added along its old path
    b2 = findfirst(
        i -> i != b && !isempty(sol0.bundle_paths[i]), eachindex(sol0.bundle_paths)
    )
    idxs = [b, b2]
    old_paths = [copy(sol0.bundle_paths[i]) for i in idxs]
    new_paths = [copy(new_path), copy(old_paths[2])]
    sol = deepcopy(sol0)
    snapshots = TPO._snapshot_multi_bundle_assignments(sol, instance, idxs)
    foreach(i -> TPO.remove_bundle_path!(sol, instance, i), idxs)
    for (i, p) in zip(idxs, new_paths)
        TPO._snapshot_path_assignments(sol, instance, i, p; cache=snapshots, clear=false)
    end
    for (i, p) in zip(idxs, new_paths)
        TPO.add_bundle_path!(sol, instance, i, p)
    end
    TPO._restore_multi_bundle_assignments!(sol, idxs, old_paths, snapshots)
    @test same_state(sol, sol0)
end

# Slice ranges `lo:hi_old` and `lo:hi_new` where `old` and `new` differ.
function differing_slice(old, new)
    lo = 1
    while lo < min(length(old), length(new)) && old[lo + 1] == new[lo + 1]
        lo += 1
    end
    # Number of common trailing nodes, the first of them ends both slices.
    common = 0
    while common < min(length(old), length(new)) - lo - 1 &&
          old[end - common] == new[end - common]
        common += 1
    end
    shrink = max(common - 1, 0)
    return lo, length(old) - shrink, length(new) - shrink
end

@testset "slice rollback restores the exact state, including edges the slice created" begin
    instance = TestFixtures.small_instance()
    sol0 = TestFixtures.small_greedy()
    b, new_path, range = 0, Int[], (0, 0, 0)
    for i in eachindex(sol0.bundle_paths)
        isempty(sol0.bundle_paths[i]) && continue
        p = alternative_path(deepcopy(sol0), instance, i)
        (isempty(p) || p == sol0.bundle_paths[i]) && continue
        lo, hi_old, hi_new = differing_slice(sol0.bundle_paths[i], p)
        snaps = TPO._snapshot_path_assignments(sol0, instance, i, view(p, lo:hi_new))
        if any(isnothing, values(snaps))
            b, new_path, range = i, p, (lo, hi_old, hi_new)
            break
        end
    end
    @test b != 0
    lo, hi_old, hi_new = range
    old_path = sol0.bundle_paths[b]

    sol = deepcopy(sol0)
    snapshots = TPO._snapshot_path_assignments(sol, instance, b, view(old_path, lo:hi_old))
    TPO.remove_bundle_subpath!(sol, instance, b, lo, hi_old)
    TPO._snapshot_path_assignments(
        sol, instance, b, view(new_path, lo:hi_new); cache=snapshots, clear=false
    )
    TPO.add_bundle_subpath!(sol, instance, b, copy(new_path), lo, hi_new)
    @test !same_state(sol, sol0)
    @test length(sol.assignments) > length(sol0.assignments)
    TPO._restore_multi_bundle_assignments!(sol, [b], [old_path], snapshots)
    @test same_state(sol, sol0)
end

@testset "a snapshot stays intact when its slot changes in place" begin
    sol = TestFixtures.small_greedy()
    slot = first(
        a for a in values(sol.assignments) if a isa TPO.SingleAssignment && !isempty(a.bins)
    )
    contents(s) = [(copy(bin.commodities), bin.remaining_capacity) for bin in s.bins]
    before = contents(slot)
    snap = TPO._snapshot_assignment(slot)
    push!(slot.bins[1].commodities, slot.bins[1].commodities[1])
    slot.bins[1].remaining_capacity -= 1.0
    push!(slot.bins, TPO.Bin([slot.commodities[1]], 0.0))
    @test [(bin.commodities, bin.remaining_capacity) for bin in snap.bins] == before
end

@testset "refine=true two-node moves keep cost(sol) equal to start minus saved" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    rng = MersenneTwister(3)
    Random.seed!(3)
    pairs = TPO.compute_candidate_nodes(instance)
    n_accepted = 0
    for _ in 1:150
        src, dst = rand(rng, pairs)
        before = deepcopy(sol)
        c0 = cost(sol)
        saved = TPO.two_node_common_incremental!(sol, instance, src, dst; refine=true)
        @test cost(sol) ≈ c0 - saved rtol = 1e-9
        if saved == 0.0
            @test same_state(sol, before)
        else
            n_accepted += 1
            @test saved > 0
        end
    end
    @test n_accepted > 0
    @test is_feasible(sol, instance)
end

@testset "restoring a snapshot of a slot without bins empties the new bins" begin
    c = LightCommodity(; origin_id="o", destination_id="d", size=5.0, info=nothing)
    slot = TPO.SingleAssignment{typeof(c)}()
    snap = TPO._snapshot_assignment(slot)
    push!(slot.commodities, c)
    push!(slot.bins, TPO.Bin([c], 95.0))
    slot.arc_cost = 3.0
    slot.node_cost = 1.0
    slot.total_size = 5.0
    TPO._restore_assignment!(slot, snap)
    @test isempty(slot.commodities) && isempty(slot.bins)
    @test slot.arc_cost == 0.0 && slot.node_cost == 0.0 && slot.total_size == 0.0
end
