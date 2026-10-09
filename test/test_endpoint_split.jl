using Test
using TransportationPlanningOptimization
using MetaGraphsNext
using Dates
using Logging
using Random

const TPO = TransportationPlanningOptimization

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
    ) match_mode = :any _instance(nodes, arcs, commodities)
    @test _types(instance) == Dict("O" => :origin, "X" => :destination, "D" => :destination)
    indexed, virtual = _arcs(instance)
    @test isempty(virtual)
    # Every loop and the arc X -> O are skipped, the other arcs keep their input index
    @test indexed == Dict(("O", "D") => 1, ("O", "X") => 3)

    # A loop on a transit=false node that is an origin and a destination is ignored
    nodes = [Node(; id="Q"), Node(; id="P", transit=false), Node(; id="R")]
    arcs = [_arc("Q", "P"), _arc("P", "R"), _arc("P", "P")]
    instance = @test_logs (:warn, r"1 loop arc\(s\) ignored") match_mode = :any _instance(
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
    instance = @test_logs loop_warning match_mode = :any _instance(nodes, arcs, [com])
    @test first(_arcs(instance)) == Dict(("A", "B") => 1, ("B", "C") => 2)
    @test isempty(only(instance.bundles).forbidden_arcs)
    solution = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(solution, instance)
    @test cost(solution) == 2.0

    # Departure mode, loop on the transit=false destination
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C", transit=false)]
    arcs = [_arc("A", "B"), _arc("B", "C"), _arc("C", "C")]
    com = _com("A", "C"; days=4, forbidden_arcs=[("C", "C")])
    instance = @test_logs loop_warning match_mode = :any _instance(nodes, arcs, [com])
    @test isempty(only(instance.bundles).forbidden_arcs)
    solution = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(solution, instance)
    @test cost(solution) == 2.0

    # Loop on a transit node, which is not a usable arc either, forbidden or not
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C")]
    arcs = [_arc("A", "B"), _arc("B", "C"), _arc("A", "A")]
    for arrival in (true, false), forbidden in (Tuple{String,String}[], [("A", "A")])
        com = _com("A", "C"; days=4, arrival, forbidden_arcs=forbidden)
        instance = @test_logs loop_warning match_mode = :any _instance(nodes, arcs, [com])
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
    instance = @test_logs (:warn, r"1 loop arc\(s\) ignored") match_mode = :any _instance(
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
