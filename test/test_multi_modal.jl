"""
Tests for multi-modal arc support: NetworkGraph auto-promotion, TSG/TTG projection
(case 1: distinct transit times, case 2: shared transit time), and end-to-end
greedy mode selection.
"""

using Test
using Graphs
using Dates
using TransportationPlanningOptimization

const TPO = TransportationPlanningOptimization

# ── Shared fixtures ────────────────────────────────────────────────────────────

const _TRUCK = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(10.0))
const _TRAIN = NetworkArc(; travel_time_steps=2, cost=LinearArcCost(5.0))

const _NODES_AB = [
    NetworkNode(; id="A", node_type=:origin, capacity=0, info=nothing),
    NetworkNode(; id="B", node_type=:destination, capacity=0, info=nothing),
]

function _ng_case1()
    return NetworkGraph(
        _NODES_AB, [("A", "B", _TRUCK), ("A", "B", _TRAIN)]; allow_multimodal=true
    )
end

function _ng_case2()
    same_speed_train = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(5.0))
    return NetworkGraph(
        _NODES_AB, [("A", "B", _TRUCK), ("A", "B", same_speed_train)]; allow_multimodal=true
    )
end

function _bundle_AB(; max_transit_steps=3)
    commodity = LightCommodity(; origin_id="A", destination_id="B", size=1.0)
    order = Order(;
        commodities=[commodity],
        time_step=1,
        max_transit_steps=max_transit_steps,
        is_date_arrival=false,
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

# ── TSG/TTG, case 1 (multi-modal-specific projection only, single-mode ────────
#    vertex/edge structure itself is owned by test_graphs.jl) ─────────────────

@testset "TSG/TTG case 1: distinct transit times keep modes on separate edges" begin
    tsg = TimeSpaceGraph(_ng_case1(), 3; wrap_time=false)
    # truck (tt=1): (A,1)→(B,2), (A,2)→(B,3), train (tt=2): (A,1)→(B,3). Distinct
    # arrival times mean these stay plain NetworkArc edges (not merged into a
    # MultiModalArc), even though the underlying NetworkGraph arc IS one.
    @test tsg.graph[("A", 1), ("B", 2)] isa NetworkArc
    @test tsg.graph[("A", 1), ("B", 3)] isa NetworkArc
    @test tsg.graph[("A", 2), ("B", 3)] isa NetworkArc

    ttg = TravelTimeGraph(_ng_case1(), [_bundle_AB(; max_transit_steps=3)])
    # truck and train project to two distinct TTG edges out of the same origin
    # node, rather than collapsing to one MultiModalArc edge.
    @test haskey(ttg.graph, ("A", 0), ("B", 1))
    @test haskey(ttg.graph, ("A", 0), ("B", 2))
end

# ── TimeSpaceGraph, case 2 ────────────────────────────────────────────────────

@testset "TimeSpaceGraph case 2: same transit time emits one MultiModalArc edge per step" begin
    tsg = TimeSpaceGraph(_ng_case2(), 3; wrap_time=false)
    # 2 nodes × 3 time steps = 6 vertices
    @test nv(tsg.graph) == 6
    # Both modes transit_time=1: (A,1)→(B,2), (A,2)→(B,3) (each a MultiModalArc)
    @test ne(tsg.graph) == 2
    @test tsg.graph[("A", 1), ("B", 2)] isa MultiModalArc
    @test length(tsg.graph[("A", 1), ("B", 2)].modes) == 2
    @test tsg.graph[("A", 2), ("B", 3)] isa MultiModalArc
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

@testset "Greedy heuristic selects cheapest mode across multi-modal scenarios" begin
    # Case 2 (same transit time -> single MultiModalArc edge): cheaper mode
    # (5.0/unit) wins over the more expensive one (10.0/unit).
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
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
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)

    sol = greedy_heuristic(instance)
    @test is_feasible(sol, instance)
    # Cheaper mode (5.0/unit) wins: 1 unit × 5.0 = 5.0
    @test cost(sol) == 5.0

    assignment = only(values(sol.assignments))
    @test assignment isa TPO.MultiAssignment
    @test length(assignment.per_mode) == 2
    # Exactly one mode slot received the commodity
    @test count(slot -> !isempty(commodities_of(slot)), assignment.per_mode) == 1

    # Case 1 (distinct transit times -> two separate TTG/TSG edges, no single
    # MultiModalArc): the cheap-but-slow train (5.0/unit, 2 days) still wins
    # over the fast-but-expensive truck (10.0/unit, 1 day) when both fit the
    # delivery deadline.
    nodes_c1 = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    arcs_c1 = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(5.0), travel_time=Day(2)
        ),
    ]
    commodities_c1 = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2024, 1, 1),
            max_delivery_time=Day(2),
            size=1.0,
        ),
    ]
    instance_c1 = Instance(nodes_c1, arcs_c1, commodities_c1, Day(1); allow_multimodal=true)
    sol_c1 = greedy_heuristic(instance_c1)
    @test is_feasible(sol_c1, instance_c1)
    @test cost(sol_c1) == 5.0

    # Heterogeneous cost function types on one MultiModalArc edge (same transit
    # time, so the two modes collapse to one edge): Linear (5.0/unit, cap 10)
    # vs. BinPacking (100.0/bin of 10). Linear is cheaper for 2 units, so all
    # commodities route there: 2 × 5.0 = 10.0.
    nodes_het = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    arcs_het = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=10,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=BinPackingArcCost(100.0, 10),
            travel_time=Day(1),
            capacity=100,
        ),
    ]
    commodities_het = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=2,
            departure_date=DateTime(2024, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance_het = Instance(
        nodes_het, arcs_het, commodities_het, Day(1); allow_multimodal=true
    )
    sol_het = greedy_heuristic(instance_het)
    @test is_feasible(sol_het, instance_het)
    @test cost(sol_het) == 10.0
end

# ── Per-mode capacity (case 2) ────────────────────────────────────────────────

@testset ":cheapest skips modes lacking capacity in case 2" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    # Cheap mode capacity=1 (cannot fit 2 units); expensive mode capacity=10
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
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    sol = greedy_heuristic(instance)

    @test is_feasible(sol, instance)
    # Cheap mode infeasible (cap=1, need=2): expensive mode wins => 2 × 10.0
    @test cost(sol) == 20.0

    assignment = only(values(sol.assignments))
    @test assignment isa TPO.MultiAssignment
    # Only the expensive mode (modes[2]) carries commodities
    @test isempty(commodities_of(assignment.per_mode[1]))
    @test length(commodities_of(assignment.per_mode[2])) == 2
end

@testset "greedy_heuristic raises ArgumentError when no mode combination has capacity" begin
    # Default (CheapestMode, no spill): neither mode alone has enough capacity
    # for 3 units (caps 1 and 2), even though the *combined* capacity would
    # suffice. CheapestMode never spills across modes, so this is infeasible.
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
            capacity=2,
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
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    @test_throws ArgumentError greedy_heuristic(instance)

    # FillThenSpillMode (spills across modes): still infeasible when the
    # *combined* capacity (1 + 2 = 3) is insufficient for the 5 units needed.
    # Regression guard: this must raise, not silently under-place commodities.
    commodities_insufficient = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=5,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance_insufficient = Instance(
        nodes, arcs, commodities_insufficient, Day(1); allow_multimodal=true
    )
    @test_throws ArgumentError greedy_heuristic(
        instance_insufficient; mode_selector=FillThenSpillMode()
    )
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
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode())

    @test is_feasible(sol, instance)
    # 1 unit on cheap mode (5.0) + 1 unit on expensive mode (10.0) = 15.0
    @test cost(sol) == 15.0

    assignment = only(values(sol.assignments))
    @test assignment isa TPO.MultiAssignment
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
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode())

    @test is_feasible(sol, instance)
    @test cost(sol) == 15.0
    assignment = only(values(sol.assignments))
    @test count(slot -> !isempty(commodities_of(slot)), assignment.per_mode) == 1
end

@testset "Symbol selector is rejected by the typed kwarg" begin
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
    @test_throws Union{TypeError,MethodError} greedy_heuristic(
        instance; mode_selector=:cheapest
    )
end

# ── Order-bucketing under wrap_time (case 2 collision on a single TSG edge) ──

@testset "wrap_time bucketing keeps placement consistent with Dijkstra estimate" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    # Two parallel modes with same transit time (case 2). Cheap mode is too
    # small for the combined wrap-collided load but big enough for either order
    # alone, which is exactly the case where per-order placement diverged from
    # the per-bundle Dijkstra estimate prior to the bucketing fix.
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
    # Two commodities with different departure dates in the same A->B bundle.
    # With wrap_time, they may project to the same TSG (B, t).
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2024, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2024, 1, 4),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(
        nodes, arcs, commodities, Day(1); wrap_time=true, allow_multimodal=true
    )

    sol = greedy_heuristic(instance)
    @test is_feasible(sol, instance)
    # Whatever the realized cost is, calling cost(sol) (sum of per-edge costs)
    # must match the cost of reconstructing the solution from the stored paths.
    # Pre-fix, these could diverge because placement and Dijkstra used different
    # per-mode accounting on the wrap-collided TSG edge.
    reconstructed = Solution(deepcopy(sol.bundle_paths), instance)
    @test is_feasible(reconstructed, instance)
    @test cost(sol) == cost(reconstructed)
end

@testset "MultiModalArc eltype: union narrowing" begin
    truck = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(10.0))
    train = NetworkArc(; travel_time_steps=2, cost=BinPackingArcCost(100.0, 10))

    # Heterogeneous cost functions: must narrow to a small Union, NOT the
    # abstract NetworkArc join. This is the inline, union-splittable layout.
    hetero = MultiModalArc([truck, train])
    ET = eltype(hetero.modes)
    @test ET == Union{typeof(truck),typeof(train)}   # narrowed, not the abstract join
    @test Base.isbitsunion(ET)                        # inline storage with type tag, no boxing
    @test hetero.modes[1] === truck
    @test hetero.modes[2] === train

    # Homogeneous cost functions: unchanged: a single concrete eltype.
    a = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(10.0))
    b = NetworkArc(; travel_time_steps=2, cost=LinearArcCost(5.0))
    homo = MultiModalArc([a, b])
    @test eltype(homo.modes) === NetworkArc{LinearArcCost,Nothing}
    @test isconcretetype(eltype(homo.modes))
end

@testset "NetworkGraph rejects pre-built MultiModalArc, abstract vectors, and duplicate legs by default" begin
    truck = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(10.0))
    train = NetworkArc(; travel_time_steps=2, cost=LinearArcCost(5.0))

    # Pre-built MultiModalArc is not accepted in the input vector.
    # Multi-modal legs must be written as multiple NetworkArc entries with the
    # same (origin_id, destination_id) so the constructor can promote them itself.
    pre_built = MultiModalArc([truck, train])
    @test_throws MethodError NetworkGraph(_NODES_AB, [("A", "B", pre_built)])

    # Vectors typed with an abstract element type are likewise rejected. Callers
    # holding heterogeneous arcs must narrow first (e.g. via collect_arcs).
    abstract_vec = Tuple{String,String,AbstractNetworkArc}[("A", "B", truck)]
    @test_throws MethodError NetworkGraph(_NODES_AB, abstract_vec)

    # Default (strict): duplicate (origin, destination) raises ArgumentError.
    @test_throws ArgumentError NetworkGraph(
        _NODES_AB, [("A", "B", truck), ("A", "B", train)]
    )

    # The supported entry path with two NetworkArc entries on the same leg still
    # promotes to a MultiModalArc edge inside the graph when opt-in is set.
    ng = NetworkGraph(
        _NODES_AB, [("A", "B", truck), ("A", "B", train)]; allow_multimodal=true
    )
    @test ng.graph["A", "B"] isa MultiModalArc
end
