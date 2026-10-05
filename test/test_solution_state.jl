using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using Test
using Dates
using Graphs
using MetaGraphsNext

@testset "SolutionState" begin
    @testset "Basic solution with LinearArcCost" begin
        # 1. Create a dummy instance
        nodes = [
            Node(; id="A", node_type=:origin, capacity=0),
            Node(; id="B", node_type=:other, capacity=0),
            Node(; id="C", node_type=:destination, capacity=0),
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
        instance = Instance(nodes, arcs, commodities, time_step)

        # 2. Check graph structure to find valid bundle paths
        @test bundle_count(instance) == 1
        @test order_count(instance) == 2
        @test commodity_count(instance) == 2
        ttg = instance.travel_time_graph

        # Path in TTG (budget 2, count up):
        # (A, 0) -> (B, 1) -> (C, 2)
        path_nodes = [("A", 0), ("B", 1), ("C", 2)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = SolutionState([path_codes], instance) # bundle index 1

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
        instance3 = Instance(nodes, arcs, commodities3, time_step)
        ttg3 = instance3.travel_time_graph
        path_nodes3 = [("A", 0), ("B", 1), ("C", 2)]
        path_codes3 = [MetaGraphsNext.code_for(ttg3.graph, n) for n in path_nodes3]
        path_with_trailing = vcat(
            path_codes3, MetaGraphsNext.code_for(ttg3.graph, ("C", 3))
        )
        sol2 = SolutionState([path_with_trailing], instance3)
        # Expect the stored bundle path to equal the cleaned original path
        @test sol2.bundle_paths[1] == path_codes3

        # Test arc costs (per-edge values in assignments)
        @test !isempty(sol.assignments)
        @test all(cost_of(a) >= 0.0 for a in values(sol.assignments))

        # Test commodities recorded on each edge
        total_commodities = sum(length(commodities_of(a)) for a in values(sol.assignments))
        @test total_commodities == 4  # 2 commodities * 2 arcs = 4
    end

    @testset "BinPackingArcCost" begin
        nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]

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
        instance = Instance(nodes, arcs, commodities, time_step)

        ttg = instance.travel_time_graph
        path_nodes = [("A", 0), ("B", 1)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = SolutionState([path_codes], instance)

        @test is_feasible(sol, instance)

        # Test bin assignments
        @test any(length(bins_of(a)) == 3 for a in values(sol.assignments))

        # Verify bin contents and metrics
        for a in values(sol.assignments)
            bins = bins_of(a)
            @test length(bins) == 3
            all_commodities = vcat([b.commodities for b in bins]...)
            @test length(all_commodities) == 3
            @test all(c.size == 6.0 for c in all_commodities)

            for bin in bins
                @test length(bin.commodities) == 1
                @test bin.remaining_capacity == 4.0
            end
        end

        # Cost should be 3 bins * 100 = 300
        @test cost(sol) == 300.0
        @test any(cost_of(a) == 300.0 for a in values(sol.assignments))
    end

    @testset "Multiple commodities with different sizes" begin
        # 1. Create a dummy instance
        nodes = [
            Node(; id="A", node_type=:origin),
            Node(; id="B", node_type=:other),
            Node(; id="C", node_type=:destination),
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
        instance = Instance(nodes, arcs, commodities, time_step)

        ttg = instance.travel_time_graph
        path_nodes = [("A", 0), ("B", 1), ("C", 2)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = SolutionState([path_codes], instance)

        @test is_feasible(sol, instance)

        # Total size = 2 + 3 = 5
        # Arc AB: 5 * 5.0 = 25.0
        # Arc BC: 5 * 3.0 = 15.0
        # Total: 40.0
        @test cost(sol) == 40.0

        # Verify individual arc costs
        @test length(sol.assignments) == 2
        edge_costs = [cost_of(a) for a in values(sol.assignments)]
        @test 25.0 in edge_costs
        @test 15.0 in edge_costs
    end

    @testset "SolutionState with Arrival Date Commodities" begin
        nodes = [
            Node(; id="A", node_type=:origin),
            Node(; id="B", node_type=:other),
            Node(; id="C", node_type=:destination),
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

        instance = Instance(nodes, arcs, commodities, time_step)

        # In Arrival setting (countdown mode):
        # We have 2 days max duration (max_transit_steps = 2).
        # We start at origin with budget 2, and arrive at destination with budget 0.
        # Path in TTG: (A, 2) -> (B, 1) -> (C, 0)
        # These project to absolute steps (1, 2, 3) in TimeSpaceGraph.
        ttg = instance.travel_time_graph
        path_nodes = [("A", 2), ("B", 1), ("C", 0)]
        path_codes = [MetaGraphsNext.code_for(ttg.graph, n) for n in path_nodes]

        sol = SolutionState([path_codes], instance)

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
        instance3 = Instance(nodes, arcs, commodities3, time_step)
        ttg3 = instance3.travel_time_graph
        path_codes3 = [
            MetaGraphsNext.code_for(ttg3.graph, ("A", 2)),
            MetaGraphsNext.code_for(ttg3.graph, ("B", 1)),
            MetaGraphsNext.code_for(ttg3.graph, ("C", 0)),
        ]
        # Prepend an extra leading timed node (A, 3) and expect it to be removed
        leading_node = MetaGraphsNext.code_for(ttg3.graph, ("A", 3))
        path_with_leading = vcat(leading_node, path_codes3)
        sol2 = SolutionState([path_with_leading], instance3)
        @test sol2.bundle_paths[1] == path_codes3

        # The cleaned path should be feasible for the instance
        @test is_feasible(sol2, instance3)
    end
end

@testset "SolutionState from paths matches incremental construction on cyclic paths" begin
    # With wrap_time the horizon is the last order step (4 here), so on the path
    # O -> X -> Y -> X -> Y the order at step 1 uses edge (X,4)->(Y,1) at its
    # fourth arc, which is also the second arc of the order at step 3.
    nodes = [
        Node(; id="O", node_type=:origin),
        Node(; id="X", node_type=:other),
        Node(; id="Y", node_type=:destination),
    ]
    arc(o, d) = Arc(;
        origin_id=o,
        destination_id=d,
        cost=BinPackingArcCost(100.0, 10),
        capacity=100,
        travel_time=Day(1),
    )
    arcs = [arc("O", "X"), arc("X", "Y"), arc("Y", "X")]
    # Sizes per order step: step 1, step 3 and step 4.
    scenarios = [
        "interleaved sizes" => ((5.0, 1.0), (3.0, 2.0), (4.0,)),
        "counterexample" => ((4.0, 4.0), (6.0, 6.0), (1.0,)),
    ]
    for (name, (sizes1, sizes3, sizes4)) in scenarios
        @testset "$name" begin
            commodity(date, size) = Commodity(;
                origin_id="O",
                destination_id="Y",
                quantity=1,
                departure_date=date,
                max_delivery_time=Day(4),
                size=size,
            )
            commodities = vcat(
                [commodity(DateTime(2021, 1, 1), s) for s in sizes1],
                [commodity(DateTime(2021, 1, 3), s) for s in sizes3],
                [commodity(DateTime(2021, 1, 4), s) for s in sizes4],
            )
            instance = Instance(nodes, arcs, commodities, Day(1); wrap_time=true)
            @test bundle_count(instance) == 1
            @test order_count(instance) == 3

            ttg = instance.travel_time_graph
            path = [
                MetaGraphsNext.code_for(ttg.graph, node) for
                node in [("O", 0), ("X", 1), ("Y", 2), ("X", 3), ("Y", 4)]
            ]
            sol = SolutionState([path], instance)
            # The path revisits X and Y on purpose, so only the loads are checked.
            @test_logs (:warn, r"elementary") match_mode = :any @test !is_feasible(
                sol, instance; verbose=true
            )
            @test TPO._check_assignment_load(sol, instance; verbose=true)

            incremental = SolutionState(instance)
            TPO.add_bundle_path!(incremental, instance, 1, copy(path))
            @test cost(sol) ≈ cost(incremental)

            for assignment in values(sol.assignments)
                slots =
                    assignment isa TPO.MultiAssignment ? assignment.per_mode : [assignment]
                for slot in slots
                    sizes = [c.size for c in slot.commodities]
                    @test issorted(sizes; rev=true)
                end
            end

            TPO.remove_bundle_path!(sol, instance, 1)
            @test cost(sol) ≈ 0.0 atol = 1e-9
        end
    end
end

mutable struct MInfo
    x::Float64
end

@testset "copy of a SolutionState" begin
    nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=2,
            departure_date=DateTime(2024, 1, 1),
            max_delivery_time=Day(2),
            size=1.0,
            info=MInfo(1.0),
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    state = greedy_heuristic(instance; show_progress=false)
    paths, state_cost = deepcopy(state.bundle_paths), cost(state)
    assignments = Dict(edge => copy(a.commodities) for (edge, a) in state.assignments)

    result = TPO.solve_state(instance; start=state, show_progress=false)
    @test is_feasible(result, instance)
    @test state.bundle_paths == paths
    @test cost(state) == state_cost
    @test Dict(edge => a.commodities for (edge, a) in state.assignments) == assignments

    duplicate = copy(state)
    @test duplicate.bundle_paths == state.bundle_paths
    @test duplicate.bundle_paths !== state.bundle_paths
    @test cost(duplicate) == state_cost
    @test is_feasible(duplicate, instance)
    TPO.remove_bundle_path!(duplicate, instance, 1)
    @test cost(duplicate) ≈ 0.0 atol = 1e-9
    @test state.bundle_paths == paths
    @test cost(state) == state_cost
    @test Dict(edge => a.commodities for (edge, a) in state.assignments) == assignments
end
