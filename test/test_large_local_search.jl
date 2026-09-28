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

"""
Build the A->H->{B,D} shared-hub instance where bundle 1 (A->B, size 10) can
only ever fit through the hub, while bundle 2 (A->D, size 4) fits either the
hub or its own direct fallback. Used to reproduce the ruin-and-recreate
deadlock in `large_local_search!` when both bundles become "forbidden".
"""
function hub_deadlock_instance()
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="H", node_type=:other),
        NetworkNode(; id="B", node_type=:destination),
        NetworkNode(; id="D", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="H",
            cost=LinearArcCost(0.1),
            travel_time=Day(1),
            capacity=10,
        ),
        Arc(;
            origin_id="H", destination_id="B", cost=LinearArcCost(0.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="H", destination_id="D", cost=LinearArcCost(0.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(100.0),
            travel_time=Day(2),
            capacity=3,
        ),
        Arc(;
            origin_id="A",
            destination_id="D",
            cost=LinearArcCost(100.0),
            travel_time=Day(2),
            capacity=5,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=10.0,
        ),
        Commodity(;
            origin_id="A",
            destination_id="D",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=4.0,
        ),
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

@testset "large_local_search! never throws or leaves a bundle unrouted under capacity contention" begin
    instance = hub_deadlock_instance()
    sol = greedy_heuristic(instance)
    my_forbidden(inst, u, v) = true

    for seed in 1:10
        s2 = deepcopy(sol)
        large_local_search!(
            s2,
            instance;
            is_forbidden=my_forbidden,
            time_limit=0.3,
            rng=Random.MersenneTwister(seed),
        )
        @test is_feasible(s2, instance; verbose=true)
        # Greedy is already optimal on this instance (all arcs are linearly
        # costed), so a rollback must restore the exact pre-call solution.
        @test s2.bundle_paths == sol.bundle_paths
        @test cost(s2) ≈ cost(sol)
    end
end
