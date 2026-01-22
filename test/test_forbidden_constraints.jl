using Test
using Dates
using TransportationPlanningOptimization
using MetaGraphsNext

@testset "Forbidden Constraints" begin
    # Setup: Simple network with 4 nodes in a diamond shape
    # A -> B -> D
    # A -> C -> D
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:other),
        NetworkNode(; id="C", node_type=:other),
        NetworkNode(; id="D", node_type=:destination),
    ]

    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(0.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="B", destination_id="D", cost=LinearArcCost(0.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="C", destination_id="D", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
    ]

    time_step = Day(1)
    base_date = DateTime(2025, 11, 20, 0, 0, 0)

    @testset "Commodity with forbidden arc" begin
        # Forbid arc A->B, should use A->C->D path
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=100.0,
                max_delivery_time=Day(3),
                forbidden_arcs=[("A", "B")],
            ),
        ]

        instance = Instance(nodes, arcs, commodities, time_step)

        # Check that bundle has the forbidden arc
        bundle = instance.bundles[1]
        @test ("A", "B") in bundle.forbidden_arcs
        @test length(bundle.forbidden_arcs) == 1
        @test isempty(bundle.forbidden_nodes)
    end

    @testset "Commodity with forbidden node" begin
        # Forbid node B, should use A->C->D path (feasible)
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=100.0,
                max_delivery_time=Day(3),
                forbidden_node_ids=["B"],
            ),
        ]

        instance = Instance(nodes, arcs, commodities, time_step)

        # Check that bundle has the forbidden node
        bundle = instance.bundles[1]
        @test "B" in bundle.forbidden_nodes
        @test length(bundle.forbidden_nodes) == 1
        @test isempty(bundle.forbidden_arcs)
    end

    @testset "Multiple commodities with different forbidden constraints" begin
        # Two commodities in same bundle with different forbidden constraints
        # Forbid B and arc A->C, but A->B->D and C->D still available (feasible)
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=50.0,
                max_delivery_time=Day(3),
                forbidden_arcs=[("A", "C")],
            ),
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=50.0,
                max_delivery_time=Day(3),
                forbidden_node_ids=["C"],
            ),
        ]

        instance = Instance(nodes, arcs, commodities, time_step)

        # Check that bundle has union of all forbidden constraints
        bundle = instance.bundles[1]
        @test "C" in bundle.forbidden_nodes
        @test ("A", "C") in bundle.forbidden_arcs
        @test length(bundle.forbidden_nodes) == 1
        @test length(bundle.forbidden_arcs) == 1
    end

    @testset "Forbidden origin raises error" begin
        # Commodity forbids its own origin - should throw error
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=100.0,
                max_delivery_time=Day(3),
                forbidden_node_ids=["A"],
            ),
        ]

        @test_throws ArgumentError Instance(nodes, arcs, commodities, time_step)
    end

    @testset "Forbidden destination raises error" begin
        # Commodity forbids its own destination - should throw error
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=100.0,
                max_delivery_time=Day(3),
                forbidden_node_ids=["D"],
            ),
        ]

        @test_throws ArgumentError Instance(nodes, arcs, commodities, time_step)
    end

    @testset "Infeasible bundle raises error" begin
        # Forbid both B and C nodes, making D unreachable from A
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=100.0,
                max_delivery_time=Day(3),
                forbidden_node_ids=["B", "C"],
            ),
        ]

        @test_throws ArgumentError Instance(nodes, arcs, commodities, time_step)
    end

    @testset "Disable feasibility check" begin
        # Same infeasible setup, but disable check - should not throw
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=100.0,
                max_delivery_time=Day(3),
                forbidden_node_ids=["B", "C"],
            ),
        ]

        # Should not throw when check is disabled
        instance = Instance(
            nodes, arcs, commodities, time_step; check_bundle_feasibility=false
        )
        @test length(instance.bundles) == 1
    end

    @testset "Greedy insertion respects forbidden constraints" begin
        # Test that the greedy algorithm actually avoids forbidden arcs
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="D",
                arrival_date=base_date + Day(3),
                size=100.0,
                max_delivery_time=Day(3),
                forbidden_node_ids=["B"],
            ),
        ]

        instance = Instance(nodes, arcs, commodities, time_step)
        solution = greedy_heuristic(instance)

        # Solution should exist and be feasible
        @test solution !== nothing
        @test length(solution.bundle_paths) == 1

        # Path should not go through B
        bundle_path = solution.bundle_paths[1]
        for node_code in bundle_path
            label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, node_code)
            node_id = label[1]
            @test node_id != "B"
        end
    end
end
