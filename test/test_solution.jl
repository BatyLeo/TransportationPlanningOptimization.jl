using NetworkDesignOptimization
using Test
using Dates
using Graphs
using MetaGraphsNext

@testset "Solution" begin
    # 1. Create a dummy instance
    nodes = [
        NetworkNode(; id="A", node_type=:origin, cost=0.0, capacity=0),
        NetworkNode(; id="B", node_type=:other, cost=1.0, capacity=0),
        NetworkNode(; id="C", node_type=:destination, cost=2.0, capacity=0),
    ]

    # Arc A->B
    arc_ab = NetworkArc(; cost=LinearArcCost(10.0), capacity=1, travel_time_steps=1)
    # Arc B->C
    arc_bc = NetworkArc(; cost=LinearArcCost(10.0), capacity=1, travel_time_steps=1)

    arcs = [("A", "B", arc_ab), ("B", "C", arc_bc)]

    time_step = Day(1)
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="C",
            quantity=1,
            departure_date=DateTime(2021, 1, 3),
            max_delivery_time=Day(2),
            size=1.0,
        ),
        Commodity(;
            origin_id="A",
            destination_id="C",
            quantity=1,
            departure_date=DateTime(2021, 1, 10),
            max_delivery_time=Day(2),
            size=1.0,
        ),
    ]
    instance = build_instance(nodes, arcs, commodities, time_step)

    # 2. Check graph structure to find valid bundle paths
    @test length(instance.bundles) == 1
    ttg = instance.travel_time_graph

    # Path in TTG (budget 2, count up):
    # (A, 0) -> (B, 1) -> (C, 2)
    path_nodes = [("A", 0), ("B", 1), ("C", 2)]
    path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

    sol = Solution([path_codes]) # bundle index 1

    @test is_feasible(sol, instance)
    @test cost(sol, instance) > 0.0 # Should compute some load
end
