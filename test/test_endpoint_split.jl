using Test
using TransportationPlanningOptimization
using MetaGraphsNext
using Dates
using Logging
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# A node cost with a fixed part, so that a wrongly charged edge shows up in the cost.
if !isdefined(Main, :SplitFixedNodeCost)
    struct SplitFixedNodeCost <: AbstractNodeCostFunction
        fixed::Float64
        per_unit::Float64
    end
    function TPO.evaluate(c::SplitFixedNodeCost, comms::Vector{<:LightCommodity})
        return isempty(comms) ? 0.0 : c.fixed + c.per_unit * sum(x.size for x in comms)
    end
end

function _arc(o, d; cost=LinearArcCost(1.0))
    return Arc(; origin_id=o, destination_id=d, cost=cost, travel_time=Day(1))
end

function _com(o, d; day=1, size=1.0, days=2, arrival=false, kwargs...)
    date = DateTime(2021, 1, day)
    dates = arrival ? (; arrival_date=date) : (; departure_date=date)
    return Commodity(;
        origin_id=o,
        destination_id=d,
        size=size,
        max_delivery_time=Day(days),
        dates...,
        kwargs...,
    )
end

function _instance(nodes, arcs, commodities; kwargs...)
    return Instance(nodes, arcs, commodities, Day(1); kwargs...)
end

# (id => node_type) of the internal nodes
function _types(instance)
    ng = instance.network_graph.graph
    return Dict(id => ng[id].node_type for id in MetaGraphsNext.labels(ng))
end

# ((tail, head) => input_index) of the internal arcs, and the set of the virtual ones
function _arcs(instance)
    ng = instance.network_graph.graph
    indexed = Dict(
        (u, v) => ng[u, v].input_index for (u, v) in MetaGraphsNext.edge_labels(ng)
    )
    virtual = Set(
        (u, v) for (u, v) in MetaGraphsNext.edge_labels(ng) if TPO._is_virtual(ng[u, v])
    )
    return indexed, virtual
end

@testset "Node input: transit and deprecated node_type" begin
    @test Node(; id="A").transit
    @test !Node(; id="A", transit=false).transit
    @test_deprecated r"node_type" Node(; id="A", node_type=:origin)
    # Any value is accepted and ignored
    @test (@test_deprecated r"node_type" Node(; id="A", node_type=:whatever)) isa Node
    @test !hasfield(Node, :node_type)
end

@testset "Role derivation, transit=true" begin
    ids = ["S", "X", "N", "Y", "Z", "W", "T"]
    nodes = [Node(; id=id) for id in ids]
    arcs = [
        _arc("S", "X"),
        _arc("X", "N"),
        _arc("N", "Y"),
        _arc("Y", "Z"),
        _arc("Z", "W"),
        _arc("W", "T"),
        _arc("Z", "T"),
    ]
    commodities = [
        _com("S", "T"; days=8),
        _com("X", "Y"; days=8),
        _com("Y", "Z"; days=8),
        _com("Z", "T"; days=8),
        _com("S", "W"; days=8),
    ]
    instance = _instance(nodes, arcs, commodities)
    types = _types(instance)
    @test types == Dict(
        "S" => :origin,
        "T" => :destination,
        "N" => :other,
        "X" => :other,
        "X_o" => :origin,
        "Y" => :other,
        "Y_o" => :origin,
        "Y_d" => :destination,
        "Z" => :other,
        "Z_o" => :origin,
        "Z_d" => :destination,
        "W" => :other,
        "W_d" => :destination,
    )
    indexed, virtual = _arcs(instance)
    @test virtual == Set([
        ("X_o", "X"), ("Y_o", "Y"), ("Y", "Y_d"), ("Z_o", "Z"), ("Z", "Z_d"), ("W", "W_d")
    ])
    # Every input arc is kept on the hubs, virtual arcs have no input index
    @test sort([i for ((u, v), i) in indexed if (u, v) ∉ virtual]) == 1:7
    @test all(indexed[a] == 0 for a in virtual)
    @test indexed[("S", "X")] == 1 && indexed[("Z", "T")] == 7
    # Copies keep the input index of their node and carry no node cost
    ng = instance.network_graph.graph
    @test ng["Y_o"].input_index == ng["Y"].input_index == 4
    @test ng["Y_o"].node_cost isa NoNodeCost
    # Bundles are rooted on the copies
    roots = Set((b.origin_id, b.destination_id) for b in instance.bundles)
    @test roots ==
        Set([("S", "T"), ("X_o", "Y_d"), ("Y_o", "Z_d"), ("Z_o", "T"), ("S", "W_d")])
    # Every commodity is mapped to its order
    @test all(!=((0, 0)), instance.commodity_to_order)
    state = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(state, instance)
end

@testset "No split keeps the node and arc types" begin
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C")]
    arcs = [_arc("A", "B"), _arc("B", "C")]
    instance = _instance(nodes, arcs, [_com("A", "C")])
    @test _types(instance) == Dict("A" => :origin, "B" => :other, "C" => :destination)
    ng = instance.network_graph.graph
    @test typeof(ng["A"]) == NetworkNode{Nothing,NoNodeCost}
    @test !occursin("VirtualArcCost", string(TPO._metagraph_edge_type(ng)))
    split_instance = _instance(nodes, arcs, [_com("A", "C"), _com("B", "C")])
    @test occursin(
        "VirtualArcCost",
        string(TPO._metagraph_edge_type(split_instance.network_graph.graph)),
    )
end

@testset "Copy ids avoid every user and copy id" begin
    nodes = [Node(; id=id) for id in ["A", "B", "B_o", "C"]]
    arcs = [_arc("A", "B"), _arc("B", "B_o"), _arc("B_o", "C"), _arc("B", "C")]
    instance = _instance(nodes, arcs, [_com("B", "C"), _com("B_o", "C")])
    types = _types(instance)
    @test types["B_o"] == :other
    @test types["B_o_o"] == :origin
    @test types["B_o_o_o"] == :origin
    @test Set(b.origin_id for b in instance.bundles) == Set(["B_o_o", "B_o_o_o"])
    _, virtual = _arcs(instance)
    @test virtual == Set([("B_o_o", "B"), ("B_o_o_o", "B_o")])
end

@testset "transit=false nodes" begin
    nodes = [
        Node(; id="Q", transit=false),
        Node(; id="P", transit=false),
        Node(; id="R", transit=false),
        Node(; id="U", transit=false),
    ]
    arcs = [
        _arc("Q", "P"),  # 1: kept
        _arc("P", "R"),  # 2: kept
        _arc("P", "Q"),  # 3: skipped, Q is not a destination
        _arc("R", "P"),  # 4: skipped, R is not an origin
        _arc("Q", "U"),  # 5: skipped, U is isolated
        _arc("U", "R"),  # 6: skipped, U is isolated
    ]
    commodities = [_com("Q", "P"), _com("P", "R")]
    instance = @test_logs (
        :warn, r"4 input arc\(s\) skipped.*1 node\(s\) with `transit=false` are neither"
    ) _instance(nodes, arcs, commodities)
    # P is both an origin and a destination: two disconnected nodes without hub
    @test _types(instance) == Dict(
        "Q" => :origin,
        "P_d" => :destination,
        "P_o" => :origin,
        "R" => :destination,
        "U" => :other,
    )
    indexed, virtual = _arcs(instance)
    @test isempty(virtual)
    @test indexed == Dict(("Q", "P_d") => 1, ("P_o", "R") => 2)
    @test Set((b.origin_id, b.destination_id) for b in instance.bundles) ==
        Set([("Q", "P_d"), ("P_o", "R")])
    @test is_feasible(greedy_heuristic(instance; show_progress=false), instance)
    # The node cost goes to the destination copy
    costed = [Node(; id="P", transit=false, node_cost=LinearNodeCost(2.0))]
    instance = _instance(
        [Node(; id="Q"), costed[1], Node(; id="R")],
        [_arc("Q", "P"), _arc("P", "R")],
        commodities,
    )
    ng = instance.network_graph.graph
    @test ng["P_d"].node_cost == LinearNodeCost(2.0)
    @test ng["P_o"].node_cost isa NoNodeCost
end

@testset "Forbidden constraints of a node without hub" begin
    nodes = [Node(; id="A"), Node(; id="B", transit=false), Node(; id="C")]
    arcs = [_arc("A", "B"), _arc("B", "C"), _arc("A", "C")]
    commodities = [
        _com("A", "C"; forbidden_node_ids=["B"], forbidden_arcs=[("A", "B"), ("B", "C")]),
        _com("A", "B"),
        _com("B", "C"),
    ]
    instance = _instance(nodes, arcs, commodities)
    bundle = only(
        b for b in instance.bundles if (b.origin_id, b.destination_id) == ("A", "C")
    )
    @test bundle.forbidden_nodes == Set(["B_o", "B_d"])
    @test bundle.forbidden_arcs == Set([("A", "B_d"), ("B_o", "C")])
    @test is_feasible(greedy_heuristic(instance; show_progress=false), instance)
    # A bundle cannot forbid its own endpoint, checked on the user ids
    bad = [_com("A", "B"; forbidden_node_ids=["B"]), _com("B", "C")]
    @test_throws ArgumentError _instance(nodes, arcs, bad)
end

# Edges of the instance that are virtual, as (u, v) TTG code pairs of `bundle_idx`
function _virtual_ttg_edges(instance, bundle_idx)
    cache = instance.index_cache
    return [
        (u, v) for (u, v) in instance.travel_time_graph.bundle_arcs[bundle_idx] if
        (arc=TPO.ttg_edge_arc(cache, u, v); !isnothing(arc) && TPO._is_virtual(arc))
    ]
end

# Assignments of the state that sit on a virtual arc
function _virtual_assignments(state, instance)
    ng = instance.network_graph.graph
    tsg = instance.time_space_graph.graph
    spatial(code) = MetaGraphsNext.label_for(tsg, code)[1]
    return [
        assignment for ((u, v), assignment) in state.assignments if
        TPO._is_virtual(ng[spatial(u), spatial(v)])
    ]
end

@testset "Cost neutrality of the endpoint split" begin
    hub_cost = SplitFixedNodeCost(100.0, 10.0)
    nodes = [
        Node(; id="A"),
        Node(; id="H", node_cost=hub_cost),
        Node(; id="B"),
        Node(; id="Z1"),
        Node(; id="Z2"),
    ]
    arcs = [_arc("A", "H"), _arc("H", "B"), _arc("Z1", "Z2")]
    # Days are given for the departure date mode, the arrival date mode shifts them by the trip
    for arrival in (false, true), wrap_time in (false, true)
        mode = "$(arrival ? "arrival" : "departure") date, wrap_time=$wrap_time"
        com(o, d, day, size, days) =
            _com(o, d; day=day + (arrival ? days : 0), size, days, arrival)
        cases = [
            ("starts at the hub", [com("H", "B", 1, 2.0, 1)], 2.0, true),
            ("ends at the hub", [com("A", "H", 1, 2.0, 1)], 2.0 + 120.0, true),
            (
                "crosses a hub that is not an endpoint (no split)",
                [com("A", "B", 1, 2.0, 2)],
                2.0 + 120.0 + 2.0,
                false,
            ),
            (
                "starts at the hub, consolidated with crossing freight",
                [com("H", "B", 2, 2.0, 1), com("A", "B", 1, 3.0, 2)],
                3.0 + 130.0 + 5.0,
                true,
            ),
            (
                "crosses a split hub",
                [
                    com("A", "B", 1, 2.0, 2),
                    com("H", "B", 2, 1.0, 1),
                    com("A", "H", 1, 1.0, 1),
                ],
                # A -> H carries 3, node cost 130, H -> B carries 3
                3.0 + 130.0 + 3.0,
                true,
            ),
        ]
        for (name, commodities, expected, is_split) in cases
            @testset "$name ($mode)" begin
                # A far away unrelated commodity (cost 1) widens the horizon, as wrap_time needs
                commodities = [commodities; com("Z1", "Z2", 7, 1.0, 1)]
                expected += 1.0
                instance = _instance(nodes, arcs, commodities; wrap_time)
                state = greedy_heuristic(instance; show_progress=false)
                @test is_feasible(state, instance)
                @test cost(state) ≈ expected
                # The cost is also the one of the full recomputation
                @test cost(SolutionState(state.bundle_paths, instance)) ≈ expected
                # Removals on the virtual arcs keep the cost consistent
                local_search!(state, instance; max_iter=20, rng=Random.MersenneTwister(1))
                @test is_feasible(state, instance)
                @test cost(state) ≈ cost(SolutionState(state.bundle_paths, instance))
                virtual_loads = _virtual_assignments(state, instance)
                @test isempty(virtual_loads) == !is_split
                @test all(a -> a.node_cost == 0.0 && a.arc_cost == 0.0, virtual_loads)
            end
        end
    end

    # The far away commodity Z1 -> Z2 (cost 1) widens the horizon, as wrap_time needs
    filler(arrival, day) = _com("Z1", "Z2"; day=day + (arrival ? 1 : 0), days=1, arrival)

    for arrival in (false, true), wrap_time in (false, true)
        mode = "$(arrival ? "arrival" : "departure") date, wrap_time=$wrap_time"
        day(d, days) = d + (arrival ? days : 0)

        @testset "consolidation on a shared edge ($mode)" begin
            # One bin of capacity 10 carries both freights, two bins would cost 20
            packed = [
                _arc("A", "H"),
                _arc("H", "B"; cost=BinPackingArcCost(10.0, 10)),
                _arc("Z1", "Z2"),
            ]
            commodities = [
                _com("H", "B"; day=day(2, 1), size=2.0, days=1, arrival),
                _com("A", "B"; day=day(1, 2), size=3.0, days=2, arrival),
                filler(arrival, 7),
            ]
            instance = _instance(nodes, packed, commodities; wrap_time)
            state = greedy_heuristic(instance; show_progress=false)
            @test is_feasible(state, instance)
            @test cost(state) ≈ 3.0 + 130.0 + 10.0 + 1.0
            shared = [
                a for a in values(state.assignments) if a isa TPO.SingleAssignment &&
                    length(a.commodities) == 2 &&
                    a.arc_cost == 10.0
            ]
            @test length(shared) == 1
            @test length(only(shared).bins) == 1
        end

        @testset "transit=false node, origin and destination ($mode)" begin
            no_transit_nodes = [
                Node(; id="A"),
                Node(; id="H", node_cost=hub_cost, transit=false),
                Node(; id="B"),
                Node(; id="Z1"),
                Node(; id="Z2"),
            ]
            commodities = [
                _com("A", "H"; size=3.0, day=day(1, 1), days=1, arrival),
                _com("H", "B"; size=2.0, day=day(2, 1), days=1, arrival),
                filler(arrival, 7),
            ]
            instance = _instance(no_transit_nodes, arcs, commodities; wrap_time)
            state = greedy_heuristic(instance; show_progress=false)
            @test is_feasible(state, instance)
            @test cost(state) ≈ 3.0 + 130.0 + 2.0 + 1.0
            @test cost(SolutionState(state.bundle_paths, instance)) ≈
                3.0 + 130.0 + 2.0 + 1.0
        end
    end
end

@testset "Virtual arc guards on removals and edge costs" begin
    hub_cost = SplitFixedNodeCost(100.0, 10.0)
    nodes = [
        Node(; id="A"), Node(; id="H", node_cost=hub_cost), Node(; id="B"), Node(; id="C")
    ]
    arcs = [_arc("A", "H"), _arc("H", "B"), _arc("H", "C")]
    # Both commodities start at H at the same date, so they share the edge (H_o, t) -> (H, t)
    commodities = [_com("H", "B"; size=2.0, days=1), _com("H", "C"; size=1.0, days=1)]
    instance = _instance(nodes, arcs, commodities)
    state = greedy_heuristic(instance; show_progress=false)
    @test cost(state) ≈ 3.0
    idx_hb = findfirst(b -> b.destination_id == "B", instance.bundles)

    @testset "edge costs" begin
        bundle = instance.bundles[idx_hb]
        edges = _virtual_ttg_edges(instance, idx_hb)
        @test !isempty(edges)
        for (u, v) in edges
            @test TPO.compute_ttg_edge_incremental_cost(state, instance, bundle, u, v) ==
                0.0
            @test TPO.compute_ttg_edge_lower_bound_cost(state, instance, bundle, u, v) ==
                0.0
            @test TPO._direct_arc_lb_cost(bundle, instance, u, v, TPO.CheapestMode()) == 0.0
        end
    end

    @testset "filled assignment" begin
        ng = instance.network_graph.graph
        loads = [instance.bundles[idx_hb].orders[1].commodities]
        @test TPO._filled_assignment(ng["H_o", "H"], loads, hub_cost).node_cost == 0.0
        @test TPO._filled_assignment(ng["H", "B"], loads, hub_cost).node_cost == 120.0
    end

    @testset "removal" begin
        TPO.remove_bundle_path!(state, instance, idx_hb)
        @test cost(state) ≈ 1.0
        @test cost(SolutionState(state.bundle_paths, instance)) ≈ 1.0
        remaining = filter(
            a -> !isempty(a.commodities), _virtual_assignments(state, instance)
        )
        @test !isempty(remaining)
        @test all(a -> a.node_cost == 0.0, remaining)
    end
end

@testset "Forbidden hub, infeasible and invalid split instances" begin
    nodes = [Node(; id=id) for id in ["A", "H", "B", "C"]]
    arcs = [
        _arc("A", "H"),
        _arc("H", "B"),
        Arc(;
            origin_id="A", destination_id="C", cost=LinearArcCost(1.5), travel_time=Day(1)
        ),
        Arc(;
            origin_id="C", destination_id="B", cost=LinearArcCost(1.5), travel_time=Day(1)
        ),
    ]
    forbids = _com("A", "B"; size=2.0, forbidden_node_ids=["H"])
    instance = _instance(nodes, arcs, [forbids, _com("H", "B"; size=1.0)])
    bundle = only(b for b in instance.bundles if b.origin_id == "A")
    @test bundle.forbidden_nodes == Set(["H"])
    state = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(state, instance)
    # A -> C -> B costs 2 * 3, the forbidden hub H would cost 4
    @test cost(state) ≈ 2 * 3.0 + 1.0

    # The construction check rejects an infeasible bundle of a split instance
    only_hub = [_arc("A", "H"), _arc("H", "B")]
    @test_throws r"infeasible bundle" _instance(nodes, only_hub, [forbids, _com("H", "B")])
    @test_throws r"infeasible bundle" _instance(
        nodes, [_arc("A", "H")], [_com("H", "B"), _com("A", "H")]
    )
    # Unsupported arc type
    abstract_arcs = Tuple{String,String,NetworkArc}[
        (a.origin_id, a.destination_id, NetworkArc(; travel_time_steps=1, cost=a.cost)) for
        a in only_hub
    ]
    @test_throws r"abstract type" TPO.build_instance(
        nodes, abstract_arcs, [_com("H", "B")], Day(1)
    )
end

@testset "Duplicated node ids are rejected" begin
    # H would be split by its commodity
    for ids in (["A", "B", "A"], ["H", "B", "H"])
        nodes = [Node(; id=id) for id in ids]
        @test_throws r"duplicate node id.*positions 1 and 3" _instance(
            nodes, [_arc(ids[1], "B")], [_com(ids[1], "B")]
        )
    end
end

@testset "Skipped arcs and crossability" begin
    # O is an origin whose only incoming arc is skipped (X is not an origin), and has a loop
    nodes = [Node(; id="O"), Node(; id="X", transit=false), Node(; id="D")]
    arcs = [_arc("O", "D"), _arc("X", "O"), _arc("O", "X"), _arc("O", "O"), _arc("X", "X")]
    commodities = [_com("O", "D"), _com("O", "X")]
    instance = @test_logs (:warn, r"2 loop arc\(s\) ignored.*arc 4 \(\"O\" -> \"O\"\)") (
        :warn, r"1 input arc\(s\) skipped"
    ) _instance(nodes, arcs, commodities)
    @test _types(instance) == Dict("O" => :origin, "X" => :destination, "D" => :destination)
    indexed, virtual = _arcs(instance)
    @test isempty(virtual)
    # Every loop and the arc X -> O are skipped, the other arcs keep their input index
    @test indexed == Dict(("O", "D") => 1, ("O", "X") => 3)

    # A loop on a transit=false node that is an origin and a destination is ignored
    nodes = [Node(; id="Q"), Node(; id="P", transit=false), Node(; id="R")]
    arcs = [_arc("Q", "P"), _arc("P", "R"), _arc("P", "P")]
    instance = @test_logs (:warn, r"1 loop arc\(s\) ignored") _instance(
        nodes, arcs, [_com("Q", "P"), _com("P", "R")]
    )
    indexed, _ = _arcs(instance)
    @test indexed == Dict(("Q", "P_d") => 1, ("P_o", "R") => 2)

    # A transit=false node with no commodity and only a loop is still reported as isolated
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="U", transit=false)]
    arcs = [_arc("A", "B"), _arc("U", "U")]
    @test_logs (:warn, r"1 loop arc\(s\) ignored") (
        :warn, r"^1 node\(s\) with `transit=false` are neither"
    ) _instance(nodes, arcs, [_com("A", "B")])
end

@testset "Forbidden arcs of skipped input arcs are kept and harmless" begin
    nodes = [
        Node(; id="A"),
        Node(; id="B", transit=false),
        Node(; id="C"),
        Node(; id="E", transit=false),
    ]
    arcs = [_arc("A", "B"), _arc("B", "C"), _arc("A", "C"), _arc("A", "E"), _arc("E", "B")]
    # The arc E -> B is skipped (E is not an origin)
    commodities = [
        _com("A", "C"; forbidden_arcs=[("E", "B"), ("A", "B")]),
        _com("A", "B"),
        _com("B", "C"),
        _com("A", "E"),
    ]
    instance = @test_logs (:warn, r"1 input arc\(s\) skipped") _instance(
        nodes, arcs, commodities
    )
    bundle = only(
        b for b in instance.bundles if (b.origin_id, b.destination_id) == ("A", "C")
    )
    @test bundle.forbidden_arcs == Set([("E", "B_d"), ("A", "B_d")])
    @test is_feasible(greedy_heuristic(instance; show_progress=false), instance)
end

@testset "Forbidden loop arcs are dropped and do not block waiting" begin
    loop_warning = (:warn, r"1 loop arc\(s\) ignored")
    # Arrival mode, loop on the transit=false origin
    nodes = [Node(; id="A", transit=false), Node(; id="B"), Node(; id="C")]
    arcs = [_arc("A", "B"), _arc("B", "C"), _arc("A", "A")]
    com = _com("A", "C"; days=4, arrival=true, forbidden_arcs=[("A", "A")])
    instance = @test_logs loop_warning _instance(nodes, arcs, [com])
    @test first(_arcs(instance)) == Dict(("A", "B") => 1, ("B", "C") => 2)
    @test isempty(only(instance.bundles).forbidden_arcs)
    solution = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(solution, instance)
    @test cost(solution) == 2.0

    # Departure mode, loop on the transit=false destination
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C", transit=false)]
    arcs = [_arc("A", "B"), _arc("B", "C"), _arc("C", "C")]
    com = _com("A", "C"; days=4, forbidden_arcs=[("C", "C")])
    instance = @test_logs loop_warning _instance(nodes, arcs, [com])
    @test isempty(only(instance.bundles).forbidden_arcs)
    solution = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(solution, instance)
    @test cost(solution) == 2.0

    # Loop on a transit node, which is not a usable arc either, forbidden or not
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C")]
    arcs = [_arc("A", "B"), _arc("B", "C"), _arc("A", "A")]
    for arrival in (true, false), forbidden in (Tuple{String,String}[], [("A", "A")])
        com = _com("A", "C"; days=4, arrival, forbidden_arcs=forbidden)
        instance = @test_logs loop_warning _instance(nodes, arcs, [com])
        @test first(_arcs(instance)) == Dict(("A", "B") => 1, ("B", "C") => 2)
        @test isempty(only(instance.bundles).forbidden_arcs)
        solution = greedy_heuristic(instance; show_progress=false)
        @test is_feasible(solution, instance)
        @test cost(solution) == 2.0
    end
end

@testset "A plan with a leg on an ignored loop arc is rejected" begin
    nodes = [Node(; id="A"), Node(; id="B")]
    arcs = [_arc("A", "A"), _arc("A", "B")]
    instance = @test_logs (:warn, r"1 loop arc\(s\) ignored") _instance(
        nodes, arcs, [_com("A", "B")]
    )
    leg = TPO.Leg(;
        arc=1, departure=DateTime(2021, 1, 1), arrival=DateTime(2021, 1, 2), quantity=1
    )
    @test_throws r"input arc 1 has no arc in the instance" SolutionState(
        TPO.Solution([[leg]], TPO.ArcFlow[]), instance
    )
end

@testset "A filtered instance keeps a forbidden node that was dropped" begin
    # P is an origin and a destination without hub, its two bundles are direct and filtered out
    nodes = [Node(; id="A"), Node(; id="X"), Node(; id="C"), Node(; id="P", transit=false)]
    arcs = [_arc("A", "X"), _arc("X", "C"), _arc("A", "P"), _arc("P", "C")]
    commodities = [
        _com("A", "C"; forbidden_node_ids=["P"], forbidden_arcs=[("A", "P")]),
        _com("A", "P"),
        _com("P", "C"),
    ]
    instance = _instance(nodes, arcs, commodities)
    result = solve_filtered(instance; show_progress=false)
    ng = result.sub_instance.network_graph.graph
    @test !haskey(ng, "P_d") && !haskey(ng, "P_o")
    kept = only(result.sub_instance.bundles)
    @test kept.forbidden_nodes == Set(["P_o", "P_d"])
    @test is_feasible(result.solution_state, result.sub_instance)
    local_search!(
        result.solution_state,
        result.sub_instance;
        max_iter=10,
        rng=Random.MersenneTwister(1),
    )
    @test is_feasible(result.solution_state, result.sub_instance)
end

@testset "Forbidden ids are validated against the user nodes" begin
    nodes = [Node(; id=id) for id in ["A", "H", "B"]]
    arcs = [_arc("A", "H"), _arc("H", "B")]
    for (kwargs, pattern) in (
        ((; forbidden_node_ids=["Hh"]), r"forbids node \"Hh\" which is not in nodes"),
        (
            (; forbidden_arcs=[("A", "Hh")]),
            r"forbids arc \(\"A\", \"Hh\"\) whose endpoint \"Hh\" is not in nodes",
        ),
        (
            (; forbidden_arcs=[("Hh", "B")]),
            r"forbids arc \(\"Hh\", \"B\"\) whose endpoint \"Hh\" is not in nodes",
        ),
        # H is split by the second commodity, its copy ids are internal
        ((; forbidden_node_ids=["H_o"]), r"forbids node \"H_o\" which is not in nodes"),
        (
            (; forbidden_arcs=[("A", "H_d")]),
            r"forbids arc \(\"A\", \"H_d\"\) whose endpoint \"H_d\" is not in nodes",
        ),
    )
        @test_throws pattern _instance(
            nodes, arcs, [_com("A", "B"; kwargs...), _com("H", "B")]
        )
    end
end

# ttg edge (u, v) of a bundle whose spatial ids are (o, d)
function _ttg_edge(instance, bundle_idx, o, d)
    ttg = instance.travel_time_graph.graph
    spatial(code) = MetaGraphsNext.label_for(ttg, code)[1]
    return only(
        (u, v) for (u, v) in instance.travel_time_graph.bundle_arcs[bundle_idx] if
        spatial(u) == o && spatial(v) == d
    )
end

# Bundle index of the input commodity k
_bundle_of(instance, k) = instance.commodity_to_order[k][1]

@testset "Direct arc position of a bundle path" begin
    for arrival in (true, false)
        # No split: a path of length 2 is direct
        nodes = [Node(; id="A"), Node(; id="B")]
        instance = _instance(nodes, [_arc("A", "B")], [_com("A", "B"; arrival)])
        cache = instance.index_cache
        path = greedy_heuristic(instance; show_progress=false).bundle_paths[1]
        @test length(path) == 2
        @test TPO._direct_arc_position(cache, path) == 1

        # S -> A -> B -> T: A and B are split by the commodities A -> B, S -> A and B -> T
        nodes = [Node(; id=id) for id in ("S", "A", "B", "T")]
        arcs = [_arc("S", "A"), _arc("A", "B"), _arc("B", "T")]
        commodities = [
            _com("A", "B"; arrival),
            _com("S", "A"; arrival),
            _com("B", "T"; arrival),
            _com("S", "T"; arrival, days=4),
        ]
        instance = _instance(nodes, arcs, commodities)
        cache = instance.index_cache
        paths = greedy_heuristic(instance; show_progress=false).bundle_paths
        position(k) = TPO._direct_arc_position(cache, paths[_bundle_of(instance, k)])
        @test length(paths[_bundle_of(instance, 1)]) == 4  # both ends split
        @test position(1) == 2
        @test length(paths[_bundle_of(instance, 2)]) == 3  # split destination
        @test position(2) == 1
        @test length(paths[_bundle_of(instance, 3)]) == 3  # split origin
        @test position(3) == 2
        @test length(paths[_bundle_of(instance, 4)]) == 4  # three real arcs
        @test position(4) == 0
        @test TPO._direct_arc_position(cache, Int[]) == 0
    end
end

@testset "A direct bundle into a split hub is filtered and preloaded on its real arc" begin
    for arrival in (true, false)
        # B is an origin and a destination, so A -> B ends with the virtual arc B -> B_d
        nodes = [Node(; id=id) for id in ("A", "B", "C")]
        arcs = [_arc("A", "B"), _arc("B", "C")]
        commodities = [
            _com("A", "B"; arrival),
            _com("B", "C"; arrival),
            _com("A", "C"; arrival, days=3),
        ]
        instance = _instance(nodes, arcs, commodities)
        result = solve_filtered(instance; show_progress=false)
        cache = instance.index_cache
        positions = [
            TPO._direct_arc_position(cache, p) for p in result.filtering_state.bundle_paths
        ]
        @test positions[_bundle_of(instance, 1)] == 1
        @test positions[_bundle_of(instance, 2)] == 2
        @test positions[_bundle_of(instance, 3)] == 0

        sub = result.sub_instance
        @test length(sub.bundles) == 1
        ng = sub.network_graph.graph
        @test haskey(ng, "B") && !haskey(ng, "B_d") && !haskey(ng, "B_o")
        # The two filtered bundles sit on the real arcs A -> B and B -> C of the sub-instance
        start = TPO.preload_filtered_bundles(result.filtering_state, instance, sub)
        tsg = sub.time_space_graph.graph
        loaded = [
            (MetaGraphsNext.label_for(tsg, u)[1], MetaGraphsNext.label_for(tsg, v)[1]) for
            ((u, v), a) in start.assignments if !isempty(a.commodities)
        ]
        @test sort(loaded) == [("A", "B"), ("B", "C")]
        @test cost(start) == 2.0
        state = solve_state(instance; show_progress=false, max_iter=10)
        @test is_feasible(state, instance)
        @test cost(state) == 4.0
    end
end

# Two bundles of size 3 from A to B (split into bundles by `info`) on an A -> B arc of
# capacity `cap` with an optional detour through H. S -> A makes A a hub, so
# A_o is a split origin copy.
function _two_direct_bundles(cap; with_hub::Bool, arrival::Bool=false)
    nodes = [Node(; id=id) for id in ("S", "A", "B")]
    arcs = [
        _arc("S", "A"),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=cap,
        ),
    ]
    if with_hub
        push!(nodes, Node(; id="H"))
        push!(arcs, _arc("A", "H"), _arc("H", "B"))
    end
    commodities = [
        _com("A", "B"; arrival, size=3.0, days=with_hub ? 2 : 1, info="p$k") for k in 1:2
    ]
    return _instance(nodes, arcs, commodities; group_by=c -> c.info)
end

@testset "Lower bound filtering gates the real arc of direct bundles from a split origin" begin
    for arrival in (true, false)
        instance = _two_direct_bundles(5; with_hub=true, arrival)
        @test "A_o" in MetaGraphsNext.labels(instance.network_graph.graph)
        filt = lower_bound_filtering(instance; show_progress=false)
        cache = instance.index_cache
        positions = [TPO._direct_arc_position(cache, p) for p in filt.bundle_paths]
        # Only one of the bundles fits on the arc, the other one takes the detour
        @test count(!=(0), positions) == 1
        @test count(==(0), positions) == 1
        @test is_feasible(filt, instance)

        res = solve_filtered(instance; show_progress=false)
        @test length(res.sub_instance.bundles) == 1
        merged = TPO.merge_solutions(filt, res.solution_state, instance, res.sub_instance)
        @test is_feasible(merged, instance)
        @test cost(merged) == 9.0

        # Without the detour the second bundle has no path left
        @test_throws "No feasible filtering path" lower_bound_filtering(
            _two_direct_bundles(5; with_hub=false, arrival); show_progress=false
        )
        # A roomy arc fixes both bundles
        roomy = _two_direct_bundles(1000; with_hub=true, arrival)
        filt = lower_bound_filtering(roomy; show_progress=false)
        @test all(
            p -> TPO._direct_arc_position(roomy.index_cache, p) != 0, filt.bundle_paths
        )
    end
end

@testset "Lower bound and filtering price the direct real arc of a split endpoint like a plain one" begin
    cost_fn = BinPackingArcCost(10.0, 10.0)
    for arrival in (true, false)
        a_b = _arc("A", "B"; cost=cost_fn)
        main = _com("A", "B"; arrival, size=3.0)
        nodes(ids) = [Node(; id=string(id)) for id in ids]
        variants = (
            # no split
            "plain" => (nodes("AB"), [a_b], [main], ()),
            # B_d: B is also an origin
            "split destination" => (
                nodes("ABC"),
                [a_b, _arc("B", "C")],
                [main, _com("B", "C"; arrival)],
                ("B_d",),
            ),
            # A_o: A is crossable through S -> A
            "split origin" => (nodes("SAB"), [_arc("S", "A"), a_b], [main], ("A_o",)),
            # A_o and B_d
            "both split" => (
                nodes("SABC"),
                [_arc("S", "A"), a_b, _arc("B", "C")],
                [main, _com("B", "C"; arrival)],
                ("A_o", "B_d"),
            ),
        )
        for (name, (ns, arcs, commodities, copy_ids)) in variants
            instance = _instance(ns, arcs, commodities)
            labels = MetaGraphsNext.labels(instance.network_graph.graph)
            @test all(in(labels), copy_ids)
            i = _bundle_of(instance, 1)
            u, v = _ttg_edge(instance, i, "A", "B")
            for price in
                (TPO.compute_ttg_edge_lower_bound_cost, TPO.compute_ttg_edge_filtering_cost)
                @test price(SolutionState(instance), instance, instance.bundles[i], u, v) ==
                    10.0
            end
        end
    end
end

@testset "Two-node candidate pairs exclude the virtual arcs" begin
    for arrival in (true, false)
        nodes = [Node(; id=id) for id in ("A", "B", "C")]
        arcs = [_arc("A", "B"), _arc("B", "C"), _arc("A", "C")]
        commodities = [
            _com("A", "B"; arrival), _com("B", "C"; arrival), _com("A", "C"; arrival)
        ]
        instance = _instance(nodes, arcs, commodities)
        g = instance.travel_time_graph.graph
        cache = instance.index_cache
        spatial(code) = MetaGraphsNext.label_for(g, code)[1]
        pairs = TPO.compute_candidate_nodes(instance)
        @test !isempty(pairs)
        @test all(((s, d),) -> !TPO._is_virtual_edge(cache, s, d), pairs)
        # The hub B has the virtual arc B -> B_d, which is a TTG edge but not a candidate
        @test any(MetaGraphsNext.edge_labels(g)) do (u, v)
            u[1] == "B" && v[1] == "B_d"
        end
        @test !any(((s, d),) -> spatial(d) == "B_d", pairs)
    end
end

# Round trip of `state` through `Solution`, `SolutionState` and CSV, with routes free of virtual arcs.
function _check_split_round_trip(state, instance)
    TestFixtures.check_round_trip(state, instance; same_cost=true)
    ns = Solution(state, instance)
    TestFixtures.check_routes(ns, state, instance)
    TestFixtures.check_flows(ns, state, instance)
    n_arcs = length(instance.input.arcs)
    @test all(leg -> 1 <= leg.arc <= n_arcs, leg for route in ns.routes for leg in route)
    @test all(f -> 1 <= f.arc <= n_arcs, ns.arc_flows)
    mktempdir() do dir
        path = joinpath(dir, "solution.csv")
        write_solution_csv(path, ns)
        @test read_solution_csv(path, instance).routes == ns.routes
    end
    return ns
end

@testset "Round trip of split instances" begin
    hub_cost = SplitFixedNodeCost(100.0, 10.0)
    arcs = [_arc("A", "H"), _arc("H", "B"), _arc("Z1", "Z2")]
    for arrival in (false, true), wrap_time in (false, true)
        mode = "$(arrival ? "arrival" : "departure") date, wrap_time=$wrap_time"
        com(o, d, day, size, days) =
            _com(o, d; day=day + (arrival ? days : 0), size, days, arrival)
        # A far away commodity widens the horizon, as wrap_time needs
        filler = com("Z1", "Z2", 7, 1.0, 1)
        nodes = [
            Node(; id="A"),
            Node(; id="H", node_cost=hub_cost),
            Node(; id="B"),
            Node(; id="Z1"),
            Node(; id="Z2"),
        ]
        cases = [
            ("starts at the hub", [com("H", "B", 1, 2.0, 1)]),
            ("ends at the hub", [com("A", "H", 1, 2.0, 1)]),
            ("crosses a hub", [com("A", "B", 1, 2.0, 2)]),
            (
                "crosses, starts and ends at the hub",
                [
                    com("A", "B", 1, 2.0, 2),
                    com("H", "B", 2, 1.0, 1),
                    com("A", "H", 1, 1.0, 1),
                ],
            ),
        ]
        for (name, commodities) in cases
            @testset "$name ($mode)" begin
                instance = _instance(nodes, arcs, [commodities; filler]; wrap_time)
                state = greedy_heuristic(instance; show_progress=false)
                _check_split_round_trip(state, instance)
                ns = Solution(state, instance)
                @test isempty(_virtual_assignments(state, instance)) ==
                    (name == "crosses a hub")
                @test all(f -> f.arc > 0, ns.arc_flows)
            end
        end
        @testset "transit=false node, origin and destination ($mode)" begin
            no_transit = [
                Node(; id="A"),
                Node(; id="H", node_cost=hub_cost, transit=false),
                Node(; id="B"),
                Node(; id="Z1"),
                Node(; id="Z2"),
            ]
            commodities = [com("A", "H", 1, 3.0, 1), com("H", "B", 2, 2.0, 1), filler]
            instance = _instance(no_transit, arcs, commodities; wrap_time)
            state = greedy_heuristic(instance; show_progress=false)
            _check_split_round_trip(state, instance)
        end
    end

    @testset "extracted sub-instances drop the unused copies and keep the used ones" begin
        # (arcs, commodities as (origin, destination, days), copies kept in the sub-instance)
        cases = [
            (
                "no copy kept",
                [("A", "H"), ("H", "B")],
                [("A", "B", 2), ("H", "B", 1), ("A", "H", 1)],
                String[],
            ),
            (
                "kept bundle starting at the hub",
                [("A", "H"), ("H", "B"), ("B", "C")],
                [("H", "C", 2), ("A", "H", 1)],
                ["H_o"],
            ),
            (
                "kept bundle ending at the hub",
                [("Z", "A"), ("A", "H"), ("H", "B")],
                [("Z", "H", 2), ("H", "B", 1)],
                ["H_d"],
            ),
        ]
        for arrival in (false, true), (name, arc_ids, specs, kept) in cases
            @testset "$name ($(arrival ? "arrival" : "departure") date)" begin
                ids = sort!(unique(vcat(collect.(arc_ids)...)))
                nodes = [Node(; id) for id in ids]
                arcs = [_arc(o, d) for (o, d) in arc_ids]
                commodities = [
                    _com(o, d; day=1 + (arrival ? days : 0), days, arrival) for
                    (o, d, days) in specs
                ]
                instance = _instance(nodes, arcs, commodities)
                @test haskey(instance.network_graph.graph, "H_o") ||
                    haskey(instance.network_graph.graph, "H_d")
                filtering = lower_bound_filtering(instance; show_progress=false)
                sub = TPO.extract_filtered_instance(instance, filtering)
                labels = Set(MetaGraphsNext.labels(sub.network_graph.graph))
                @test intersect(labels, ["H_o", "H_d"]) == Set(kept)
                @test "H" in labels
                state = greedy_heuristic(sub; show_progress=false)
                if isempty(kept)
                    @test bundle_count(sub) == 1
                else
                    # the kept bundle goes through the hop
                    @test !isempty(_virtual_assignments(state, sub))
                end
                _check_split_round_trip(state, sub)
            end
        end
    end
end

@testset "Multi-modal arcs next to virtual edges" begin
    modes = [(10.0, 3), (5.0, 3), (20.0, 100)]
    mode_arcs(o, d) = [
        Arc(;
            origin_id=o,
            destination_id=d,
            cost=LinearArcCost(c),
            travel_time=Day(1),
            capacity=cap,
        ) for (c, cap) in modes
    ]
    nodes = [Node(; id="A"), Node(; id="H"), Node(; id="B")]
    arcs = [mode_arcs("A", "H"); mode_arcs("H", "B")]
    for arrival in (false, true), selector in (CheapestMode(), FillThenSpillMode())
        @testset "$(nameof(typeof(selector))) ($(arrival ? "arrival" : "departure") date)" begin
            commodities = [
                _com("A", "H"; arrival, day=1, days=1, quantity=4),
                _com("H", "B"; arrival, day=1 + (arrival ? 1 : 0), days=1, quantity=4),
                _com("A", "B"; arrival, day=1 + (arrival ? 2 : 0), days=2, quantity=2),
            ]
            instance = _instance(nodes, arcs, commodities; allow_multimodal=true)
            state = greedy_heuristic(instance; mode_selector=selector, show_progress=false)
            @test !isempty(_virtual_assignments(state, instance))
            ns = _check_split_round_trip(state, instance)
            rebuilt = SolutionState(ns, instance)
            @test TestFixtures.edge_multisets(rebuilt) == TestFixtures.edge_multisets(state)
            @test cost(rebuilt) ≈ cost(state)
        end
    end
end

@testset "Two orders of one bundle on a split instance" begin
    hub_cost = SplitFixedNodeCost(100.0, 10.0)
    nodes = [
        Node(; id="A"),
        Node(; id="H", node_cost=hub_cost),
        Node(; id="B"),
        Node(; id="Z1"),
        Node(; id="Z2"),
    ]
    arcs = [_arc("A", "H"), _arc("H", "B"), _arc("Z1", "Z2")]
    for arrival in (false, true), wrap_time in (false, true)
        mode = "$(arrival ? "arrival" : "departure") date, wrap_time=$wrap_time"
        com(o, d, day, size) =
            _com(o, d; day=day + (arrival ? 1 : 0), size, days=1, arrival)
        @testset "starting at the hub ($mode)" begin
            commodities = [
                com("H", "B", 1, 2.0),
                com("H", "B", 3, 1.0),
                com("A", "H", 1, 1.0),
                com("Z1", "Z2", 7, 1.0),
            ]
            instance = _instance(nodes, arcs, commodities; wrap_time)
            @test any(b -> length(b.orders) == 2, instance.bundles)
            state = greedy_heuristic(instance; show_progress=false)
            _check_split_round_trip(state, instance)
        end
        @testset "ending at the hub ($mode)" begin
            commodities = [
                com("A", "H", 1, 2.0),
                com("A", "H", 3, 1.0),
                com("H", "B", 1, 1.0),
                com("Z1", "Z2", 7, 1.0),
            ]
            instance = _instance(nodes, arcs, commodities; wrap_time)
            @test any(b -> length(b.orders) == 2, instance.bundles)
            state = greedy_heuristic(instance; show_progress=false)
            _check_split_round_trip(state, instance)
        end
    end
end

# The message of the `ArgumentError` thrown when rebuilding the state of the `routes`.
function _rebuild_message(instance, routes)
    try
        SolutionState(Solution(routes, TPO.ArcFlow[]), instance)
    catch e
        return e isa ArgumentError ? e.msg : rethrow()
    end
    return error("the plan was not rejected")
end

@testset "Rejected plans on split instances name user ids" begin
    leg(arc, day) = TPO.Leg(;
        arc,
        departure=DateTime(2021, 1, day),
        arrival=DateTime(2021, 1, day + 1),
        quantity=1,
    )
    function check(instance, routes, fragment)
        message = _rebuild_message(instance, routes)
        @test occursin(fragment, message)
        @test !occursin(r"_[od]\b", message)
    end
    nodes = [Node(; id="A"), Node(; id="H"), Node(; id="B")]
    arcs = [_arc("A", "H"), _arc("H", "B"), _arc("A", "B")]
    commodities = [
        _com("A", "B"; days=2, forbidden_node_ids=["H"]),
        _com("H", "B"; days=1),
        _com("A", "H"; days=1),
    ]
    instance = _instance(nodes, arcs, commodities)
    valid = [[leg(3, 1)], [leg(2, 1)], [leg(1, 1)]]
    @test is_feasible(SolutionState(Solution(valid, TPO.ArcFlow[]), instance), instance)
    check(instance, [valid[1], [leg(1, 1)], valid[3]], "not at the commodity origin H")
    check(instance, [[leg(1, 1), leg(2, 3)], valid[2], valid[3]], "waits at H")
    check(instance, [[leg(1, 1), leg(2, 2)], valid[2], valid[3]], "forbidden node H")
    check(instance, [valid[1], valid[2], [leg(3, 1)]], "not at the commodity destination H")

    @testset "transit=false nodes" begin
        nodes = [Node(; id="A"), Node(; id="X", transit=false), Node(; id="B")]
        arcs = [_arc("A", "X"), _arc("X", "B")]
        commodities = [_com("A", "X"), _com("X", "B"), _com("A", "B"; days=2)]
        instance = _instance(nodes, arcs, commodities; check_bundle_feasibility=false)
        check(
            instance,
            [[leg(1, 1)], [leg(2, 1)], [leg(1, 1), leg(2, 2)]],
            "the route crosses node X, which has `transit=false`",
        )

        # P is neither an origin nor a destination, its arcs are never created
        nodes = [Node(; id="A"), Node(; id="P", transit=false), Node(; id="B")]
        arcs = [_arc("A", "P"), _arc("P", "B")]
        instance = @test_logs (:warn, r"2 input arc\(s\) skipped") _instance(
            nodes, arcs, [_com("A", "B"; days=2)]; check_bundle_feasibility=false
        )
        check(instance, [[leg(1, 1), leg(2, 2)]], "input arc 1 has no arc in the instance")

        # The forbidden arc (A, X) enters the hubless node X
        nodes = [
            Node(; id="A"), Node(; id="Y"), Node(; id="X", transit=false), Node(; id="B")
        ]
        arcs = [_arc("A", "X"), _arc("A", "Y"), _arc("Y", "X"), _arc("X", "B")]
        commodities = [_com("A", "X"; days=2, forbidden_arcs=[("A", "X")]), _com("X", "B")]
        instance = _instance(nodes, arcs, commodities)
        alternative = [[leg(2, 1), leg(3, 2)], [leg(4, 1)]]
        @test is_feasible(
            SolutionState(Solution(alternative, TPO.ArcFlow[]), instance), instance
        )
        check(instance, [[leg(1, 1)], [leg(4, 1)]], "forbidden arc (\"A\", \"X\")")
    end

    @testset "construction feasibility message" begin
        nodes = [Node(; id="A"), Node(; id="H"), Node(; id="B")]
        arcs = [_arc("A", "H"), _arc("H", "B")]
        commodities = [_com("A", "H"), _com("H", "B"; forbidden_arcs=[("H", "B")])]
        message = try
            _instance(nodes, arcs, commodities)
            ""
        catch e
            e.msg
        end
        @test occursin("H → B", message)
        @test !occursin(r"_[od]\b", message)
    end
end
