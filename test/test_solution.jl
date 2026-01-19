using NetworkDesignOptimization
using Test
using Dates
using Graphs
using MetaGraphsNext

@testset "Solution" begin
    @testset "Basic solution with LinearArcCost" begin
        # 1. Create a dummy instance
        nodes = [
            NetworkNode(; id="A", node_type=:origin, cost=0.0, capacity=0),
            NetworkNode(; id="B", node_type=:other, cost=1.0, capacity=0),
            NetworkNode(; id="C", node_type=:destination, cost=2.0, capacity=0),
        ]

        # Arc A->B
        arc_ab = Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(10.0),
            capacity=1,
            travel_time=Day(1),
        )
        # Arc B->C
        arc_bc = Arc(;
            origin_id="B",
            destination_id="C",
            cost=LinearArcCost(10.0),
            capacity=1,
            travel_time=Day(1),
        )

        arcs = [arc_ab, arc_bc]

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
        instance = build_instance(nodes, arcs, commodities, time_step, LinearArcCost)

        # 2. Check graph structure to find valid bundle paths
        @test bundle_count(instance) == 1
        @test order_count(instance) == 2
        @test commodity_count(instance) == 2
        ttg = instance.travel_time_graph

        # Path in TTG (budget 2, count up):
        # (A, 0) -> (B, 1) -> (C, 2)
        path_nodes = [("A", 0), ("B", 1), ("C", 2)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = Solution([path_codes], instance) # bundle index 1

        @test is_feasible(sol, instance)
        @test cost(sol) > 0.0 # Should compute some load

        # Test that trailing shortcuts are removed: create an instance with larger horizon
        commodities3 = [
            Commodity(;
                origin_id="A",
                destination_id="C",
                quantity=1,
                departure_date=DateTime(2021, 1, 3),
                max_delivery_time=Day(3),
                size=1.0,
            ),
        ]
        instance3 = build_instance(nodes, arcs, commodities3, time_step, LinearArcCost)
        ttg3 = instance3.travel_time_graph
        path_nodes3 = [("A", 0), ("B", 1), ("C", 2)]
        path_codes3 = [MetaGraphsNext.code_for(ttg3.graph, n) for n in path_nodes3]
        path_with_trailing = vcat(
            path_codes3, MetaGraphsNext.code_for(ttg3.graph, ("C", 3))
        )
        sol2 = Solution([path_with_trailing], instance3)
        # Expect the stored bundle path to equal the cleaned original path
        @test sol2.bundle_paths[1] == path_codes3

        # Test arc_costs dictionary
        @test !isempty(sol.arc_costs)
        @test all(c >= 0.0 for c in values(sol.arc_costs))

        # Test commodities_on_arcs
        @test !isempty(sol.commodities_on_arcs)
        total_commodities = sum(length(comms) for comms in values(sol.commodities_on_arcs))
        @test total_commodities == 4  # 2 commodities * 2 arcs = 4
    end

    @testset "BinPackingArcCost" begin
        nodes = [
            NetworkNode(; id="A", node_type=:origin),
            NetworkNode(; id="B", node_type=:destination),
        ]

        # Arc with bin-packing cost: 100 per bin, capacity 10
        arc_ab = Arc(;
            origin_id="A",
            destination_id="B",
            cost=BinPackingArcCost(100.0, 10),
            capacity=100,
            travel_time=Day(1),
        )
        arcs = [arc_ab]

        time_step = Day(1)
        # 3 commodities with size 6 each = 18 total
        # Lower bound: ceil(18/10) = 2
        # FFD: needs 3 bins (6+6 > 10)
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="B",
                quantity=1,
                departure_date=DateTime(2021, 1, 1),
                max_delivery_time=Day(1),
                size=6.0,
            ),
            Commodity(;
                origin_id="A",
                destination_id="B",
                quantity=1,
                departure_date=DateTime(2021, 1, 1),
                max_delivery_time=Day(1),
                size=6.0,
            ),
            Commodity(;
                origin_id="A",
                destination_id="B",
                quantity=1,
                departure_date=DateTime(2021, 1, 1),
                max_delivery_time=Day(1),
                size=6.0,
            ),
        ]
        instance = build_instance(nodes, arcs, commodities, time_step, BinPackingArcCost)

        ttg = instance.travel_time_graph
        path_nodes = [("A", 0), ("B", 1)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = Solution([path_codes], instance)

        @test is_feasible(sol, instance)

        # Test bin assignments with Bin struct
        @test !isempty(sol.bin_assignments)
        # Total size = 18, bin capacity = 10, but need 3 bins due to FFD logic
        @test any(length(bins) == 3 for bins in values(sol.bin_assignments))

        # Verify bin contents and metrics
        for bins in values(sol.bin_assignments)
            @test length(bins) == 3
            all_commodities = vcat([b.commodities for b in bins]...)
            @test length(all_commodities) == 3
            @test all(c.size == 6.0 for c in all_commodities)

            # Verify each bin's metrics
            for bin in bins
                @test length(bin.commodities) == 1
                @test bin.total_size == 6.0
                @test bin.max_capacity == 10.0
                @test bin.remaining_capacity == 4.0
            end
        end

        # Cost should be 3 bins * 100 = 300
        @test cost(sol) == 300.0

        # Test arc_costs
        @test any(c == 300.0 for c in values(sol.arc_costs))
    end

    @testset "Multiple commodities with different sizes" begin
        # 1. Create a dummy instance
        nodes = [
            NetworkNode(; id="A", node_type=:origin),
            NetworkNode(; id="B", node_type=:other),
            NetworkNode(; id="C", node_type=:destination),
        ]

        # Arcs A->B and B->C
        arc_ab = Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(5.0), travel_time=Day(1)
        )
        arc_bc = Arc(;
            origin_id="B", destination_id="C", cost=LinearArcCost(3.0), travel_time=Day(1)
        )

        arcs = [arc_ab, arc_bc]

        time_step = Day(1)
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="C",
                quantity=1,
                departure_date=DateTime(2021, 1, 1),
                max_delivery_time=Day(2),
                size=2.0,
            ),
            Commodity(;
                origin_id="A",
                destination_id="C",
                quantity=1,
                departure_date=DateTime(2021, 1, 1),
                max_delivery_time=Day(2),
                size=3.0,
            ),
        ]
        instance = build_instance(nodes, arcs, commodities, time_step, LinearArcCost)

        ttg = instance.travel_time_graph
        path_nodes = [("A", 0), ("B", 1), ("C", 2)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = Solution([path_codes], instance)

        @test is_feasible(sol, instance)

        # Total size = 2 + 3 = 5
        # Arc AB: 5 * 5.0 = 25.0
        # Arc BC: 5 * 3.0 = 15.0
        # Total: 40.0
        @test cost(sol) == 40.0

        # Verify individual arc costs
        @test length(sol.arc_costs) == 2
        @test 25.0 in values(sol.arc_costs)
        @test 15.0 in values(sol.arc_costs)
    end

    @testset "Solution with Arrival Date Commodities" begin
        nodes = [
            NetworkNode(; id="A", node_type=:origin),
            NetworkNode(; id="B", node_type=:other),
            NetworkNode(; id="C", node_type=:destination),
        ]

        # Arcs with Day(1) travel time
        arc_ab = Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(10.0), travel_time=Day(1)
        )
        arc_bc = Arc(;
            origin_id="B", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(1)
        )
        arcs = [arc_ab, arc_bc]

        time_step = Day(1)
        # Arrival at 2021-01-05, max delivery time 2 days -> released at 2021-01-03
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="C",
                quantity=1,
                arrival_date=DateTime(2021, 1, 5),
                max_delivery_time=Day(2),
                size=1.0,
            ),
        ]

        instance = build_instance(nodes, arcs, commodities, time_step, LinearArcCost)

        # In Arrival setting (countdown mode):
        # We have 2 days max duration (max_transit_steps = 2).
        # We start at origin with budget 2, and arrive at destination with budget 0.
        # Path in TTG: (A, 2) -> (B, 1) -> (C, 0)
        # These project to absolute steps (1, 2, 3) in TimeSpaceGraph.
        ttg = instance.travel_time_graph
        path_nodes = [("A", 2), ("B", 1), ("C", 0)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = Solution([path_codes], instance)

        @test is_feasible(sol, instance)
        # 1 commodity on 2 arcs, unit cost 10.0, size 1.0 -> 20.0 total
        @test cost(sol) == 20.0
        @test bundle_count(instance) == 1
        @test commodity_count(instance) == 1

        # Test that leading shortcuts are removed: create an instance with larger horizon
        commodities3 = [
            Commodity(;
                origin_id="A",
                destination_id="C",
                quantity=1,
                arrival_date=DateTime(2021, 1, 5),
                max_delivery_time=Day(3),
                size=1.0,
            ),
        ]
        instance3 = build_instance(nodes, arcs, commodities3, time_step, LinearArcCost)
        ttg3 = instance3.travel_time_graph
        path_codes3 = [
            MetaGraphsNext.code_for(ttg3.graph, ("A", 2)),
            MetaGraphsNext.code_for(ttg3.graph, ("B", 1)),
            MetaGraphsNext.code_for(ttg3.graph, ("C", 0)),
        ]
        # Prepend an extra leading timed node (A, 3) and expect it to be removed
        leading_node = MetaGraphsNext.code_for(ttg3.graph, ("A", 3))
        path_with_leading = vcat(leading_node, path_codes3)
        sol2 = Solution([path_with_leading], instance3)
        @test sol2.bundle_paths[1] == path_codes3

        # The cleaned path should be feasible for the instance
        @test is_feasible(sol2, instance3)
    end
end
