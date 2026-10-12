using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "slope_scaling_update! populates cost_scaling" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()

    @test isempty(instance.travel_time_graph.cost_scaling)
    slope_scaling_update!(instance, sol)
    @test !isempty(instance.travel_time_graph.cost_scaling)
end

@testset "slope_scaling_update! factors are between 0 and 2" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    slope_scaling_update!(instance, sol)

    for factor in values(instance.travel_time_graph.cost_scaling)
        @test 0.0 < factor <= 2.0
    end
end

@testset "slope_scaling_update! on empty solution leaves cost_scaling empty" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = SolutionState(instance)
    slope_scaling_update!(instance, sol)
    @test isempty(instance.travel_time_graph.cost_scaling)
end

@testset "slope_scaling_update! excludes factors of exactly 1.0" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    slope_scaling_update!(instance, sol)

    for factor in values(instance.travel_time_graph.cost_scaling)
        @test !isapprox(factor, 1.0; atol=1e-9)
    end
end

@testset "slope_scaling_update! clears stale entries between calls" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    slope_scaling_update!(instance, sol)
    @test !isempty(instance.travel_time_graph.cost_scaling)

    empty_sol = SolutionState(instance)
    slope_scaling_update!(instance, empty_sol)
    @test isempty(instance.travel_time_graph.cost_scaling)
end

@testset "slope scaling does not change insertions or local search" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    base = greedy_heuristic(instance; show_progress=false)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    factors = Random.MersenneTwister(7)
    for arcs in ttg.bundle_arcs, (u, v) in arcs
        ttg.cost_scaling[TPO.ttg_edge_key(cache, u, v)] = 1 + 2 * rand(factors)
    end

    scaled = greedy_heuristic(instance; show_progress=false)
    @test scaled.bundle_paths == base.bundle_paths
    @test cost(scaled) == cost(base)

    local_search_run(sol) = local_search!(
        sol, instance; time_limit=600, max_iter=300, rng=Random.MersenneTwister(1)
    )
    ls_scaled = deepcopy(base)
    local_search_run(ls_scaled)
    TestFixtures.reset!()
    ls_plain = deepcopy(base)
    local_search_run(ls_plain)
    @test ls_scaled.bundle_paths == ls_plain.bundle_paths
    @test cost(ls_scaled) == cost(ls_plain)
end

@testset "iterated_local_search! resets the slope scaling" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    config = ILSConfig(; time_limit=3, perturbation_time_limit=1, ls_time_limit=1)
    scaling_was_set = Ref(false)
    function recording_update!(inst, s)
        slope_scaling_update!(inst, s)
        scaling_was_set[] |= !isempty(inst.travel_time_graph.cost_scaling)
        return nothing
    end
    iterated_local_search!(
        sol,
        instance,
        [TestFixtures.ReinsertPerturbation()];
        config,
        (cost_update!)=recording_update!,
        rng=Random.MersenneTwister(42),
        verbose=false,
    )
    @test scaling_was_set[]
    @test isempty(instance.travel_time_graph.cost_scaling)

    function failing_update!(inst, s)
        slope_scaling_update!(inst, s)
        @test !isempty(inst.travel_time_graph.cost_scaling)
        return error("boom")
    end
    @test_throws ErrorException iterated_local_search!(
        TestFixtures.small_greedy(),
        instance,
        [TestFixtures.ReinsertPerturbation()];
        config,
        (cost_update!)=failing_update!,
        verbose=false,
    )
    @test isempty(instance.travel_time_graph.cost_scaling)
end
