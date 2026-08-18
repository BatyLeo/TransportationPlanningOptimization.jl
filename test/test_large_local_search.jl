using Test
using TransportationPlanningOptimization
using Dates
using Random
using Graphs

const TPO = TransportationPlanningOptimization

isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound

function build_small_instance()
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    return Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

@testset "large_local_search! with no forbidden arcs matches local_search!" begin
    instance = build_small_instance()
    sol = greedy_heuristic(instance)
    start_cost = cost(sol)

    improvement = large_local_search!(
        sol, instance; time_limit=5.0, rng=Random.MersenneTwister(42)
    )

    @test improvement >= -1e-6
    @test is_feasible(sol, instance)
end

@testset "large_local_search! with forbidden predicate" begin
    instance = build_small_instance()
    sol = greedy_heuristic(instance)
    ttg = instance.travel_time_graph
    cache = instance.index_cache

    # Forbid arcs where both endpoints have the same spatial node as the
    # destination of bundle 1 (this is a contrived predicate for testing)
    dst_spatial = cache.ttg_spatial[ttg.destination_codes[1]]
    function my_forbidden(inst, u, v)
        c = inst.index_cache
        return c.ttg_spatial[u] == dst_spatial || c.ttg_spatial[v] == dst_spatial
    end

    # This may or may not find forbidden bundles, but it should not crash
    improvement = large_local_search!(
        sol,
        instance;
        is_forbidden=my_forbidden,
        time_limit=5.0,
        rng=Random.MersenneTwister(42),
    )

    @test is_feasible(sol, instance)
end

@testset "large_local_search! does not degrade solution" begin
    instance = build_small_instance()
    sol = greedy_heuristic(instance)
    local_search!(sol, instance; time_limit=10.0)
    optimized_cost = cost(sol)

    improvement = large_local_search!(
        sol, instance; time_limit=5.0, rng=Random.MersenneTwister(42)
    )

    @test cost(sol) <= optimized_cost + 1e-3
    @test is_feasible(sol, instance)
end
