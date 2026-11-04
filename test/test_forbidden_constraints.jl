using Test
using Dates
using TransportationPlanningOptimization
using Graphs
using MetaGraphsNext

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# Setup: Simple network with 4 nodes in a diamond shape
# A -> B -> D
# A -> C -> D
nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C"), Node(; id="D")]

arcs = [
    Arc(; origin_id="A", destination_id="B", cost=LinearArcCost(0.0), travel_time=Day(1)),
    Arc(; origin_id="A", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(1)),
    Arc(; origin_id="B", destination_id="D", cost=LinearArcCost(0.0), travel_time=Day(1)),
    Arc(; origin_id="C", destination_id="D", cost=LinearArcCost(10.0), travel_time=Day(1)),
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
    instance = Instance(nodes, arcs, commodities, time_step; check_bundle_feasibility=false)
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
    solution = greedy_heuristic(instance; show_progress=false)

    # Solution should exist and be feasible
    @test !isnothing(solution)
    @test length(solution.bundle_paths) == 1

    # Path should not go through B
    bundle_path = solution.bundle_paths[1]
    for node_code in bundle_path
        label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, node_code)
        node_id = label[1]
        @test node_id != "B"
    end
end

# ── Resolution of the user ids to internal spatial codes ──────────────────────

const TPO = TransportationPlanningOptimization

@testset "Resolved forbidden codes of an unsplit diamond" begin
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="D",
            arrival_date=base_date + Day(3),
            size=100.0,
            max_delivery_time=Day(3),
            forbidden_node_ids=["B"],
            forbidden_arcs=[("A", "B")],
        ),
    ]
    instance = Instance(nodes, arcs, commodities, time_step)
    fc = TestFixtures._forbidden(instance, only(instance.bundles))
    @test fc.nodes == TestFixtures._code_set(instance, ["B"])
    @test fc.arcs == TestFixtures._code_pairs(instance, [("A", "B")])
end

@testset "Resolved forbidden codes of a hub" begin
    hub_nodes = [Node(; id=id) for id in ["A", "H", "B", "C"]]
    hub_arcs = [
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(c), travel_time=Day(1)) for
        (o, d, c) in [("A", "H", 1.0), ("H", "B", 1.0), ("A", "C", 1.5), ("C", "B", 1.5)]
    ]
    function com(o, d; kwargs...)
        return Commodity(;
            origin_id=o,
            destination_id=d,
            size=1.0,
            departure_date=base_date,
            max_delivery_time=Day(2),
            kwargs...,
        )
    end
    hub_coms = [com("A", "B"; forbidden_node_ids=["H"]), com("H", "B")]
    instance = Instance(hub_nodes, hub_arcs, hub_coms, Day(1))
    bundle = only(
        b for b in instance.bundles if
        (TPO._user_id(instance, b.origin_id), TPO._user_id(instance, b.destination_id)) ==
        ("A", "B")
    )
    fc = TestFixtures._forbidden(instance, bundle)
    @test fc.nodes == TestFixtures._code_set(instance, ["H", "H_o"])
    @test isempty(fc.arcs)
    state = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(state, instance)
    @test cost(state) ≈ 3.0 + 1.0
end

@testset "Resolved forbidden arcs of a multi-modal pair" begin
    # Two A -> B arcs (two modes) give a single code pair, the greedy takes the other route
    mm_nodes = [Node(; id=id) for id in ["A", "B", "C"]]
    mm_arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(2.0), travel_time=Day(2)
        ),
        Arc(;
            origin_id="A", destination_id="C", cost=LinearArcCost(5.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="C", destination_id="B", cost=LinearArcCost(5.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            departure_date=base_date,
            max_delivery_time=Day(3),
            forbidden_arcs=[("A", "B")],
        ),
    ]
    instance = Instance(mm_nodes, mm_arcs, commodities, Day(1); allow_multimodal=true)
    fc = TestFixtures._forbidden(instance, only(instance.bundles))
    @test isempty(fc.nodes)
    @test fc.arcs == TestFixtures._code_pairs(instance, [("A", "B")])
    state = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(state, instance)
    @test cost(state) ≈ 10.0
end

@testset "A forbidden loop on a hub resolves to no arc" begin
    # A is the origin of one commodity and the destination of another, so it is split into A, A_o and A_d
    loop_nodes = [Node(; id=id) for id in ["X", "A", "B"]]
    loop_arcs = [
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(1))
        for (o, d) in [("X", "A"), ("A", "B")]
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            departure_date=base_date,
            max_delivery_time=Day(2),
            forbidden_arcs=[("A", "A")],
        ),
        Commodity(;
            origin_id="X",
            destination_id="A",
            size=1.0,
            departure_date=base_date,
            max_delivery_time=Day(2),
        ),
    ]
    instance = Instance(loop_nodes, loop_arcs, commodities, Day(1))
    @test haskey(instance.network_graph.graph, "A_o")
    bundle = only(
        b for b in instance.bundles if TPO._user_id(instance, b.destination_id) == "B"
    )
    # The construction filter empties the stored set
    @test isempty(bundle.forbidden_arcs)
    fc = TestFixtures._forbidden(instance, bundle)
    @test isempty(fc.nodes) && isempty(fc.arcs)
    # A bundle built elsewhere keeps the loop, the resolver itself skips it
    loop_bundle = TPO.Bundle(;
        orders=bundle.orders,
        origin_id=bundle.origin_id,
        destination_id=bundle.destination_id,
        forbidden_arcs=Set([("A", "A")]),
    )
    @test isempty(TestFixtures._resolved_forbidden(instance, loop_bundle).arcs)
    state = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(state, instance)
end

@testset "The is_feasible warning names the user arc, not the endpoint copy" begin
    # X has no hub, so the bundle A -> X ends on the copy X_d
    w_nodes = [
        Node(; id="A"), Node(; id="Y"), Node(; id="X", transit=false), Node(; id="B")
    ]
    w_arcs = [
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(1))
        for (o, d) in [("A", "X"), ("A", "Y"), ("Y", "X"), ("X", "B")]
    ]
    commodity(o, d; kwargs...) = Commodity(;
        origin_id=o,
        destination_id=d,
        size=1.0,
        departure_date=base_date,
        max_delivery_time=Day(2),
        kwargs...,
    )
    commodities = [commodity("A", "X"; forbidden_arcs=[("A", "X")]), commodity("X", "B")]
    instance = Instance(w_nodes, w_arcs, commodities, Day(1))
    bundle_idx = findfirst(
        b -> TPO._user_id(instance, b.destination_id) == "X" && b.origin_id == "A",
        instance.bundles,
    )
    ttg = instance.travel_time_graph
    state = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(state, instance)
    # Route the bundle on the forbidden direct edge A -> X_d (then the waiting edge to the destination)
    spatial = instance.index_cache.ttg_code_to_spatial_code
    x_d = code_for(instance.network_graph.graph, "X_d")
    first_hop = only(
        v for v in Graphs.outneighbors(ttg.graph, ttg.origin_codes[bundle_idx]) if
        spatial[v] == x_d
    )
    path = unique([
        ttg.origin_codes[bundle_idx], first_hop, ttg.destination_codes[bundle_idx]
    ])
    @test Graphs.has_edge(ttg.graph, path[end - 1], path[end])
    state.bundle_paths[bundle_idx] = path
    @test @test_logs (:warn, r"forbidden arc \(A, X\)") match_mode = :any !is_feasible(
        state, instance; verbose=true
    )
end
