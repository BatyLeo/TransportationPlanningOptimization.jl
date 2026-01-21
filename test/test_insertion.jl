using TransportationPlanningOptimization
using Test
using Dates
using MetaGraphsNext

@testset "Greedy Insertion" begin
    # 1. Setup a simple network: A -> B -> C
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:other),
        NetworkNode(; id="C", node_type=:destination),
        NetworkNode(; id="D", node_type=:destination),
    ]

    # Arcs A->B, B->C, B->D
    arc_ab = Arc(;
        origin_id="A", destination_id="B", cost=LinearArcCost(10.0), travel_time=Day(1)
    )
    arc_bc = Arc(;
        origin_id="B", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(1)
    )
    arc_bd = Arc(;
        origin_id="B", destination_id="D", cost=LinearArcCost(10.0), travel_time=Day(1)
    )
    arcs_linear = [arc_ab, arc_bc, arc_bd]

    time_step = Day(1)

    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="C",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=1.0,
        ),
    ]

    instance = Instance(nodes, arcs_linear, commodities, time_step)

    # Helper to find bundle index by origin/destination
    function find_bundle_idx(inst, org, dst)
        return findfirst(b -> b.origin_id == org && b.destination_id == dst, inst.bundles)
    end

    @testset "Empty Solution Initialization" begin
        sol = Solution(instance)
        @test bundle_count(instance) == 1
        @test isempty(sol.bundle_paths[1])
        @test isempty(sol.commodities_on_arcs)
        @test cost(sol) == 0.0
    end

    @testset "Insert Bundle (LinearArcCost)" begin
        sol = Solution(instance)
        idx = find_bundle_idx(instance, "A", "C")
        insert_bundle!(sol, instance, idx)

        @test !isempty(sol.bundle_paths[1])
        # Two arcs (A->B, B->C), size 1.0, cost 10.0 each -> 20.0
        @test cost(sol) == 20.0
        @test is_feasible(sol, instance)
    end

    @testset "Greedy Construction (LinearArcCost)" begin
        sol = greedy_construction(instance)
        @test cost(sol) == 20.0
        @test is_feasible(sol, instance)
    end

    # 2. BinPackingArcCost Test
    # Bundle 1 goes A->B->C
    # Bundle 2 goes A->B->D
    arc_ab_bp = Arc(;
        origin_id="A",
        destination_id="B",
        cost=BinPackingArcCost(100.0, 10),
        travel_time=Day(1),
    )
    arc_bc_bp = Arc(;
        origin_id="B",
        destination_id="C",
        cost=BinPackingArcCost(100.0, 10),
        travel_time=Day(1),
    )
    arc_bd_bp = Arc(;
        origin_id="B",
        destination_id="D",
        cost=BinPackingArcCost(100.0, 10),
        travel_time=Day(1),
    )
    arcs_bp = [arc_ab_bp, arc_bc_bp, arc_bd_bp]

    # Bundle 1: 3 objects of size 6.0
    comms_bp_1 = [
        Commodity(;
            origin_id="A",
            destination_id="C",
            quantity=3,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=6.0,
        ),
    ]
    # Bundle 2: 1 object of size 3.0
    comms_bp_2 = [
        Commodity(;
            origin_id="A",
            destination_id="D",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=3.0,
        ),
    ]

    instance_bp = Instance(nodes, arcs_bp, vcat(comms_bp_1, comms_bp_2), time_step)

    @testset "Incremental Insertion (BinPackingArcCost)" begin
        sol = Solution(instance_bp)

        # Insert first bundle (3 items of size 6.0)
        # Should take 3 bins per arc. (3 bins * 100 * 2 arcs = 600)
        idx1 = find_bundle_idx(instance_bp, "A", "C")
        insert_bundle!(sol, instance_bp, idx1)
        @test cost(sol) == 600.0

        # Insert second bundle (1 item of size 3.0)
        # Each of the 3 bins on AB has 4.0 remaining capacity. 3.0 from bundle 2 should fit in one of them.
        # But bundle 2 also uses B->D which is a new arc (1 new bin).
        # Total cost: A->B (3 bins) + B->C (3 bins) + B->D (1 bin) = 700.0
        idx2 = find_bundle_idx(instance_bp, "A", "D")
        insert_bundle!(sol, instance_bp, idx2)
        @test cost(sol) == 700.0
        @test is_feasible(sol, instance_bp)

        # Check that we have 2 bundles in the solution
        @test all(!isempty(p) for p in sol.bundle_paths)
    end
end
