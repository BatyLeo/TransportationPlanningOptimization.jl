using Test
using TransportationPlanningOptimization
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "GroupReinsertPerturbation accepted moves" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    p = GroupReinsertPerturbation()
    rng = Random.MersenneTwister(1)
    changed = Int[]
    for _ in 1:15
        before = cost(sol)
        (inc, n) = perturbate!(sol, instance, p; rng)
        push!(changed, n)
        @test cost(sol) - before ≈ inc atol = 1e-6
        @test inc <= p.tolerance * before + 1e-9
        @test is_feasible(sol, instance)
    end
    @test any(>(0), changed)
end

@testset "GroupReinsertPerturbation rejection restores the solution" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    sol0 = copy(sol)
    p = GroupReinsertPerturbation(; tolerance=-1.0)
    rng = Random.MersenneTwister(2)
    for _ in 1:5
        @test perturbate!(sol, instance, p; rng) == (0.0, 0)
        @test TestFixtures.same_state(sol, sol0)
        @test is_feasible(sol, instance)
    end
end

@testset "A failed reinsertion is always rolled back" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    sol0 = copy(sol)
    for tolerance in (0.015, Inf)
        result = TPO._reroute_bundles!(
            sol, instance, [1, 2]; tolerance
        ) do s, inst, snapshots
            TPO._try_insert_bundle!(s, inst, 1; snapshots)
            return false
        end
        @test result == (0.0, 0)
        @test TestFixtures.same_state(sol, sol0)
    end
end

@testset "GroupReinsertPerturbation is deterministic" begin
    instance = TestFixtures.small_instance()
    sol1 = TestFixtures.small_greedy()
    sol2 = copy(sol1)
    p = GroupReinsertPerturbation()
    rng1 = Random.MersenneTwister(3)
    rng2 = Random.MersenneTwister(3)
    for _ in 1:5
        r1 = perturbate!(sol1, instance, p; rng=rng1)
        r2 = perturbate!(sol2, instance, p; rng=rng2)
        @test r1 == r2
        @test sol1.bundle_paths == sol2.bundle_paths
    end
end

@testset "GroupReinsertPerturbation origin grouping" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    p = GroupReinsertPerturbation(; group_by=b -> b.origin_id)
    rng = Random.MersenneTwister(4)
    for _ in 1:10
        before = cost(sol)
        (inc, _) = perturbate!(sol, instance, p; rng)
        @test cost(sol) - before ≈ inc atol = 1e-6
        @test is_feasible(sol, instance)
    end
end

@testset "ILS with GroupReinsertPerturbation" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    start_cost = cost(sol)
    result = iterated_local_search!(
        sol,
        instance,
        [GroupReinsertPerturbation()];
        config=ILSConfig(; time_limit=4, perturbation_time_limit=2, ls_time_limit=1),
        rng=Random.MersenneTwister(5),
        verbose=false,
    )
    @test result.best_cost <= start_cost + 1e-6
    @test cost(sol) <= start_cost + 1e-6
    @test is_feasible(sol, instance)
end

@testset "GroupReinsertPerturbation with FillThenSpillMode on a multimodal instance" begin
    # FillThenSpill packs 3 + 2 (cost 24), CheapestMode would put 5 on the 10.0 mode (cost 30).
    modes = [(BinPackingArcCost(10.0, 2), 1, 10), (BinPackingArcCost(7.0, 2), 1, 3)]
    instance = TestFixtures._leg_instance(modes, 1; quantity=5)
    selector = FillThenSpillMode()
    sol = greedy_heuristic(instance; mode_selector=selector, show_progress=false)
    @test any(a -> a isa TPO.MultiAssignment, values(sol.assignments))
    p = GroupReinsertPerturbation(; tolerance=Inf)
    rng = Random.MersenneTwister(1)
    for _ in 1:5
        (inc, _) = perturbate!(sol, instance, p; rng, mode_selector=selector)
        @test inc ≈ 0 atol = 1e-9
        @test any(a -> a isa TPO.MultiAssignment, values(sol.assignments))
        @test is_feasible(Solution(sol, instance), instance)
    end
end
