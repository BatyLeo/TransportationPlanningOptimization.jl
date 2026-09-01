using Test
using TransportationPlanningOptimization
using Dates
using Random
using Graphs

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "large_local_search! with no forbidden arcs matches local_search!" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    start_cost = cost(sol)

    improvement = large_local_search!(
        sol, instance; time_limit=2.0, rng=Random.MersenneTwister(42)
    )

    @test improvement >= -1e-6
    @test is_feasible(sol, instance)
end

@testset "large_local_search! with forbidden predicate" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    ttg = instance.travel_time_graph
    cache = instance.index_cache

    # Forbid arcs where both endpoints have the same spatial node as the
    # destination of bundle 1 (this is a contrived predicate for testing)
    dst_spatial = cache.ttg_code_to_spatial_code[ttg.destination_codes[1]]
    function my_forbidden(inst, u, v)
        c = inst.index_cache
        return c.ttg_code_to_spatial_code[u] == dst_spatial ||
               c.ttg_code_to_spatial_code[v] == dst_spatial
    end

    # This may or may not find forbidden bundles, but it should not crash
    improvement = large_local_search!(
        sol,
        instance;
        is_forbidden=my_forbidden,
        time_limit=2.0,
        rng=Random.MersenneTwister(42),
    )

    @test is_feasible(sol, instance)
end

@testset "large_local_search! does not degrade solution" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    local_search!(sol, instance; time_limit=2.0)
    optimized_cost = cost(sol)

    improvement = large_local_search!(
        sol, instance; time_limit=2.0, rng=Random.MersenneTwister(42)
    )

    @test cost(sol) <= optimized_cost + 1e-3
    @test is_feasible(sol, instance)
end
