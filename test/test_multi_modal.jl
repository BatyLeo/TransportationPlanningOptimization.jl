"""
Tests for multi-modal arc support: NetworkGraph auto-promotion, TSG/TTG projection
(case 1: distinct transit times, case 2: shared transit time), and end-to-end
greedy mode selection.
"""

using Test
using Graphs
using Dates
using TransportationPlanningOptimization

# ── Shared fixtures ────────────────────────────────────────────────────────────

const _TRUCK = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(10.0))
const _TRAIN = NetworkArc(; travel_time_steps=2, cost=LinearArcCost(5.0))

const _NODES_AB = [
    NetworkNode(; id="A", node_type=:origin, cost=0.0, capacity=0, info=nothing),
    NetworkNode(; id="B", node_type=:destination, cost=0.0, capacity=0, info=nothing),
]

function _ng_case1()
    return NetworkGraph(_NODES_AB, [("A", "B", _TRUCK), ("A", "B", _TRAIN)])
end

function _ng_case2()
    same_speed_train = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(5.0))
    return NetworkGraph(_NODES_AB, [("A", "B", _TRUCK), ("A", "B", same_speed_train)])
end

function _bundle_AB(; max_transit_steps=3)
    commodity = LightCommodity(;
        origin_id="A", destination_id="B", size=1.0, is_date_arrival=false
    )
    order = Order(;
        commodities=[commodity], time_step=1, max_transit_steps=max_transit_steps
    )
    return Bundle(; orders=[order], origin_id="A", destination_id="B")
end

# ── NetworkGraph auto-promotion ────────────────────────────────────────────────

@testset "NetworkGraph promotes duplicate leg to MultiModalArc" begin
    ng = _ng_case1()
    @test ne(ng.graph) == 1
    edge_data = ng.graph["A", "B"]
    @test edge_data isa MultiModalArc
    @test length(edge_data.modes) == 2
end

# ── TimeSpaceGraph, case 1 ────────────────────────────────────────────────────

@testset "TimeSpaceGraph case 1: each mode becomes a distinct edge" begin
    tsg = TimeSpaceGraph(_ng_case1(), 3; wrap_time=false)
    # 2 nodes × 3 time steps = 6 vertices
    @test nv(tsg.graph) == 6
    # truck (tt=1): (A,1)→(B,2), (A,2)→(B,3)  = 2 arcs
    # train (tt=2): (A,1)→(B,3)                = 1 arc
    @test ne(tsg.graph) == 3
    # Each edge carries the original single-mode NetworkArc
    @test tsg.graph[("A", 1), ("B", 2)] isa NetworkArc
    @test tsg.graph[("A", 1), ("B", 3)] isa NetworkArc
    @test tsg.graph[("A", 2), ("B", 3)] isa NetworkArc
end

# ── TimeSpaceGraph, case 2 ────────────────────────────────────────────────────

@testset "TimeSpaceGraph case 2: same transit time emits one MultiModalArc edge per step" begin
    tsg = TimeSpaceGraph(_ng_case2(), 3; wrap_time=false)
    # 2 nodes × 3 time steps = 6 vertices
    @test nv(tsg.graph) == 6
    # Both modes transit_time=1: (A,1)→(B,2), (A,2)→(B,3) — each a MultiModalArc
    @test ne(tsg.graph) == 2
    @test tsg.graph[("A", 1), ("B", 2)] isa MultiModalArc
    @test length(tsg.graph[("A", 1), ("B", 2)].modes) == 2
    @test tsg.graph[("A", 2), ("B", 3)] isa MultiModalArc
end

# ── TravelTimeGraph, case 1 ───────────────────────────────────────────────────

@testset "TravelTimeGraph case 1: each mode becomes a distinct edge" begin
    ttg = TravelTimeGraph(_ng_case1(), [_bundle_AB(; max_transit_steps=3)])
    # Vertices: (A,0) + (B,0)…(B,3) = 5
    @test nv(ttg.graph) == 5
    # Arcs: truck (A,0)→(B,1), train (A,0)→(B,2), shortcuts (B,0..2)→(B,1..3) = 5
    @test ne(ttg.graph) == 5
    @test haskey(ttg.graph, ("A", 0), ("B", 1))
    @test haskey(ttg.graph, ("A", 0), ("B", 2))
end

# ── TravelTimeGraph, case 2 ───────────────────────────────────────────────────

@testset "TravelTimeGraph case 2: same transit time emits one MultiModalArc edge" begin
    ttg = TravelTimeGraph(_ng_case2(), [_bundle_AB(; max_transit_steps=3)])
    # Vertices: (A,0) + (B,0)…(B,3) = 5
    @test nv(ttg.graph) == 5
    # 1 multi-modal arc (A,0)→(B,1) + 3 shortcuts (B,0..2)→(B,1..3) = 4
    @test ne(ttg.graph) == 4
    @test haskey(ttg.graph, ("A", 0), ("B", 1))
    @test ttg.graph[("A", 0), ("B", 1)] isa MultiModalArc
    @test length(ttg.graph[("A", 0), ("B", 1)].modes) == 2
end

# ── Greedy mode selection (case 2) ────────────────────────────────────────────

@testset "Greedy heuristic selects cheapest mode in case 2" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    # Two arcs with same transit time: truck 10.0/unit, train 5.0/unit
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(5.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))

    sol = greedy_heuristic(instance)
    @test is_feasible(sol, instance)
    # Cheaper mode (5.0/unit) wins: 1 unit × 5.0 = 5.0
    @test cost(sol) == 5.0

    assignment = only(values(sol.assignments))
    @test assignment isa MultiAssignment
    @test length(assignment.per_mode) == 2
    # Exactly one mode slot received the commodity
    @test count(slot -> !isempty(commodities_of(slot)), assignment.per_mode) == 1
end

# ── Per-mode capacity (case 2) ────────────────────────────────────────────────

@testset "is_feasible detects per-mode capacity overflow in case 2" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    # Cheap mode capacity=1; expensive mode capacity=10
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=1,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(10.0),
            travel_time=Day(1),
            capacity=10,
        ),
    ]
    # 2 units: greedy always picks the cheap mode, overflowing its capacity
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=2,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    sol = greedy_heuristic(instance)
    @test !is_feasible(sol, instance; verbose=false)
end

# ── fill_then_spill mode selection (case 2) ──────────────────────────────────

@testset "fill_then_spill assigns to cheapest then spills" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=1,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(10.0),
            travel_time=Day(1),
            capacity=10,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=2,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    sol = greedy_heuristic(instance; mode_selection=:fill_then_spill)

    @test is_feasible(sol, instance)
    # 1 unit on cheap mode (5.0) + 1 unit on expensive mode (10.0) = 15.0
    @test cost(sol) == 15.0

    assignment = only(values(sol.assignments))
    @test assignment isa MultiAssignment
    @test count(slot -> !isempty(commodities_of(slot)), assignment.per_mode) == 2
end

@testset "fill_then_spill matches cheapest when capacity is sufficient" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=100,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(10.0),
            travel_time=Day(1),
            capacity=100,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=3,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    sol = greedy_heuristic(instance; mode_selection=:fill_then_spill)

    @test is_feasible(sol, instance)
    @test cost(sol) == 15.0
    assignment = only(values(sol.assignments))
    @test count(slot -> !isempty(commodities_of(slot)), assignment.per_mode) == 1
end

@testset "invalid mode_selection throws ArgumentError" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(5.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    @test_throws ArgumentError greedy_heuristic(instance; mode_selection=:invalid)
end
