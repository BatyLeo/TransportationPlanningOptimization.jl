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
