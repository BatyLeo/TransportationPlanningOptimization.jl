using TransportationPlanningOptimization
using Dates
using Test

@testset "Quick Start example" begin
    # This test mirrors the Quick Start in docs/src/index.md and README.md.
    # If this breaks, update both.

    nodes = [
        NetworkNode(; id="Origin", node_type=:origin),
        NetworkNode(; id="Hub", node_type=:other),
        NetworkNode(; id="Destination", node_type=:destination),
    ]

    arcs = [
        Arc(;
            origin_id="Origin",
            destination_id="Hub",
            cost=LinearArcCost(10.0),
            travel_time=Day(1),
        ),
        Arc(;
            origin_id="Hub",
            destination_id="Destination",
            cost=LinearArcCost(10.0),
            travel_time=Day(1),
        ),
    ]

    commodities = [
        Commodity(;
            origin_id="Origin",
            destination_id="Destination",
            arrival_date=DateTime(2025, 1, 3),
            max_delivery_time=Day(2),
            size=5.0,
        ),
    ]

    instance = Instance(nodes, arcs, commodities, Day(1))
    solution = greedy_heuristic(instance)

    @test is_feasible(solution, instance)
    @test cost(solution) > 0
end

"""
Build the A->H->{B,D} shared-hub instance used by the capacity testsets below.
`hub_cost` prices the shared, capacitated `A->H` leg, `direct_cost` prices the
uncapacitated `A->B` / `A->D` fallback arcs, and `leg_cost` prices the final
`H->B` / `H->D` leg. A bundle routes all of its commodities along one shared
path, so capacity is exercised across the two bundles that both need the
`A->H` leg, not within a single bundle.
"""
function hub_capacity_instance(hub_cost, direct_cost, leg_cost)
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="H", node_type=:other),
        NetworkNode(; id="B", node_type=:destination),
        NetworkNode(; id="D", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="H", cost=hub_cost, travel_time=Day(1), capacity=1
        ),
        Arc(; origin_id="H", destination_id="B", cost=leg_cost, travel_time=Day(1)),
        Arc(; origin_id="H", destination_id="D", cost=leg_cost, travel_time=Day(1)),
        Arc(; origin_id="A", destination_id="B", cost=direct_cost, travel_time=Day(2)),
        Arc(; origin_id="A", destination_id="D", cost=direct_cost, travel_time=Day(2)),
    ]
    commodities = [
        # Larger, so it is always inserted first by `greedy_heuristic`.
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=1.0,
        ),
        Commodity(;
            origin_id="A",
            destination_id="D",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=0.9,
        ),
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

@testset "greedy_heuristic respects single-mode NetworkArc capacity" begin
    # `allow_multimodal` is irrelevant here: the two competing routes are
    # A->H->{B,D} and A->{B,D}, distinct legs, not duplicate (origin,
    # destination) pairs, so both stay plain `NetworkArc`s.
    instance = hub_capacity_instance(
        LinearArcCost(0.5), LinearArcCost(10.0), LinearArcCost(0.5)
    )
    sol = greedy_heuristic(instance)
    @test is_feasible(sol, instance; verbose=true)
    # First bundle fits the cheap hub path (0.5 + 0.5 = 1.0), filling the
    # A->H capacity. The second bundle must take its expensive direct arc.
    @test cost(sol) ≈ 1.0 + 10.0 * 0.9
end

@testset "greedy_heuristic with fixed-charge SumArcCost respects capacity" begin
    instance = hub_capacity_instance(
        SumArcCost((LinearArcCost(1.0), BinPackingArcCost(5.0, 1))),
        LinearArcCost(20.0),
        LinearArcCost(0.0),
    )
    sol = greedy_heuristic(instance)
    @test is_feasible(sol, instance; verbose=true)
    # Fixed charge (bin cost 5.0) is paid exactly once, on the first bundle
    # that fits the capacitated hub arc. The second bundle overflows it and
    # falls back to its expensive direct arc, no second bin opened.
    @test cost(sol) ≈ (1.0 + 5.0) + 20.0 * 0.9
end

@testset "greedy_heuristic avoids an arc smaller than the commodity" begin
    # A single commodity larger than the only capacitated arc's capacity
    # must not be routed onto it. No alternative route exists here, so
    # `greedy_heuristic` throws.
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=1,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=2.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    @test_throws ArgumentError greedy_heuristic(instance)
end
