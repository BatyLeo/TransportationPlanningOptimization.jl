"""
Tests for Instance creation and integration using Inbound test application
"""

using CSV
using Dates
using TransportationPlanningOptimization
using Test

using TransportationPlanningOptimization.Problems.Inbound

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "Instance creation" begin
    @test begin
        nodes = [
            Node(; id="1", node_type=:origin, capacity=100, info=nothing),
            Node(; id="2", node_type=:destination, capacity=200, info=nothing),
        ]
        arcs = [
            Arc(;
                origin_id="1",
                destination_id="2",
                travel_time=Week(0),
                cost=LinearArcCost(5.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=10.0,
                quantity=5,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        instance = Instance(nodes, arcs, commodities, Week(1))
        length(instance.bundles) > 0
    end
end

@testset "Instance with Inbound test data" begin
    inbound_data_dir = joinpath(@__DIR__, "public")
    nodes_file = joinpath(inbound_data_dir, "small_nodes.csv")
    legs_file = joinpath(inbound_data_dir, "small_legs.csv")
    routes_file = joinpath(inbound_data_dir, "small_routes.csv")
    commodities_file = joinpath(inbound_data_dir, "small_commodities.csv")

    @test isfile(nodes_file) &&
        isfile(legs_file) &&
        isfile(routes_file) &&
        isfile(commodities_file)
    (; nodes, arcs, commodities) = parse_inbound_instance(
        nodes_file, legs_file, commodities_file
    )
    instance = Instance(nodes, arcs, commodities, Week(1))
    @test fieldtype(typeof(instance), :time_step) === Week
    nb_bundles = length(instance.bundles)
    nb_orders = sum(length(bundle.orders) for bundle in instance.bundles)
    nb_commodities = sum(
        length(order.commodities) for bundle in instance.bundles for order in bundle.orders
    )
    @test nb_bundles == 312
    @test nb_orders == 1983
    @test nb_commodities == 45323
end

@testset "Instance bundle aggregation" begin
    @test begin
        nodes = [
            Node(; id="A", node_type=:origin, capacity=50, info=nothing),
            Node(; id="B", node_type=:other, capacity=100, info=nothing),
            Node(; id="C", node_type=:destination, capacity=150, info=nothing),
        ]
        arcs = [
            Arc(;
                origin_id="A",
                destination_id="B",
                travel_time=Week(0),
                cost=LinearArcCost(2.0),
                info=nothing,
            ),
            Arc(;
                origin_id="B",
                destination_id="C",
                travel_time=Week(0),
                cost=LinearArcCost(3.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="B",
                size=5.0,
                quantity=2,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
            Commodity(;
                origin_id="A",
                destination_id="B",
                size=7.0,
                quantity=3,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
            Commodity(;
                origin_id="B",
                destination_id="C",
                size=10.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 2),
                max_delivery_time=Week(2),
            ),
        ]
        # Note: The B->C bundle is infeasible because it starts at (B, 2) in the
        # travel-time graph (countdown mode) but B is an intermediate node with no
        # wait arcs, and C is a destination appearing only at time 0. The B->C arc
        # with zero travel time creates (B,0)->(C,0) but not (B,2)->(C,0).
        # This is a real limitation of the current time-expanded graph construction.
        instance = Instance(
            nodes, arcs, commodities, Week(1); check_bundle_feasibility=false
        )
        # Should create 2 bundles: A->B and B->C
        length(instance.bundles) == 2
    end
end

@testset "Instance with linear arc costs" begin
    @test begin
        nodes = [
            Node(; id="1", node_type=:origin, capacity=1000, info=nothing),
            Node(; id="2", node_type=:destination, capacity=1000, info=nothing),
        ]
        arcs = [
            Arc(;
                origin_id="1",
                destination_id="2",
                travel_time=Week(0),
                cost=LinearArcCost(1.5),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=20.0,
                quantity=5,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        instance = Instance(nodes, arcs, commodities, Week(1))
        instance.bundles[1].origin_id == "1" && instance.bundles[1].destination_id == "2"
    end
end

@testset "Instance with bin packing arc costs" begin
    @test begin
        nodes = [
            Node(; id="1", node_type=:origin, capacity=500, info=nothing),
            Node(; id="2", node_type=:destination, capacity=500, info=nothing),
        ]
        arcs = [
            Arc(;
                origin_id="1",
                destination_id="2",
                travel_time=Week(0),
                cost=BinPackingArcCost(100.0, 50.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=15.0,
                quantity=3,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        instance = Instance(nodes, arcs, commodities, Week(1))
        length(instance.bundles) == 1
    end
end

@testset "Instance with heterogeneous arc costs" begin
    @test begin
        nodes = [
            Node(; id="1", node_type=:origin, capacity=1000, info=nothing),
            Node(; id="2", node_type=:other, capacity=1000, info=nothing),
            Node(; id="3", node_type=:destination, capacity=1000, info=nothing),
        ]
        arcs = [
            Arc(;
                origin_id="1",
                destination_id="2",
                travel_time=Week(0),
                cost=LinearArcCost(2.0),
                info=nothing,
            ),
            Arc(;
                origin_id="2",
                destination_id="3",
                travel_time=Week(0),
                cost=BinPackingArcCost(50.0, 40.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=10.0,
                quantity=2,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
            Commodity(;
                origin_id="2",
                destination_id="3",
                size=25.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        # Note: Similar to above, the 2->3 bundle is infeasible in the time-expanded graph
        # because 2 is an intermediate node with no wait arcs and can't route through
        # the zero-travel-time arc to destination 3.
        instance = Instance(
            nodes, arcs, commodities, Week(1); check_bundle_feasibility=false
        )
        length(instance.bundles) == 2
    end
end

@testset "Instance time period handling" begin
    @test begin
        nodes = [
            Node(; id="1", node_type=:origin, capacity=100, info=nothing),
            Node(; id="2", node_type=:destination, capacity=100, info=nothing),
        ]
        arcs = [
            Arc(;
                origin_id="1",
                destination_id="2",
                travel_time=Week(0),
                cost=LinearArcCost(1.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=5.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(2),
            ),
        ]
        # Test with different time periods
        instance_week = Instance(nodes, arcs, commodities, Week(1))
        instance_day = Instance(nodes, arcs, commodities, Day(1))
        length(instance_week.bundles) == 1 && length(instance_day.bundles) == 1
    end
end

@testset "Instance with custom group_by" begin
    @test begin
        struct TestInfo
            model::String
        end
        nodes = [
            Node(; id="A", node_type=:origin, capacity=10, info=nothing),
            Node(; id="B", node_type=:destination, capacity=10, info=nothing),
        ]
        arcs = [
            Arc(;
                origin_id="A",
                destination_id="B",
                travel_time=Week(0),
                cost=LinearArcCost(1.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="B",
                size=1.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
                info=TestInfo("X"),
            ),
            Commodity(;
                origin_id="A",
                destination_id="B",
                size=1.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
                info=TestInfo("Y"),
            ),
        ]
        # Default group_by: both in one bundle
        instance_default = Instance(nodes, arcs, commodities, Week(1))
        # Custom group_by: separate bundles by model
        instance_grouped = Instance(
            nodes, arcs, commodities, Week(1); group_by=c -> c.info.model
        )
        # The default grouping key is `nothing`; the custom key is the model string.
        default_group_ok =
            length(instance_default.bundles) == 1 &&
            isnothing(instance_default.bundles[1].group)
        grouped_groups = Set(b.group for b in instance_grouped.bundles)
        grouped_ok =
            length(instance_grouped.bundles) == 2 && grouped_groups == Set(["X", "Y"])
        default_group_ok && grouped_ok
    end
end

@testset "Instance keeps input and commodity mapping" begin
    nodes = [
        Node(; id="A", node_type=:origin, capacity=100, info=nothing),
        Node(; id="C", node_type=:origin, capacity=100, info=nothing),
        Node(; id="B", node_type=:destination, capacity=100, info=nothing),
    ]
    mk_arc(o, d) = Arc(;
        origin_id=o,
        destination_id=d,
        travel_time=Day(1),
        cost=LinearArcCost(1.0),
        info=nothing,
    )
    arcs = [mk_arc("A", "B"), mk_arc("C", "B")]
    mk_com(o, size, quantity, day) = Commodity(;
        origin_id=o,
        destination_id="B",
        size=size,
        quantity=quantity,
        arrival_date=DateTime(2024, 1, day),
        max_delivery_time=Day(2),
    )
    commodities = [
        mk_com("A", 2.0, 3, 5),
        mk_com("A", 1.0, 1, 5),
        mk_com("A", 1.0, 1, 6),
        mk_com("C", 1.0, 1, 5),
    ]

    function check_mapping(instance, commodities=commodities)
        c2o = instance.commodity_to_order
        @test length(c2o) == length(commodities)
        for (k, commodity) in enumerate(commodities)
            b, o = c2o[k]
            @test 1 <= b <= length(instance.bundles)
            @test 1 <= o <= length(instance.bundles[b].orders)
            @test instance.bundles[b].origin_id == commodity.origin_id
            @test instance.bundles[b].destination_id == commodity.destination_id
            date = instance.time_step_to_date[instance.bundles[b].orders[o].time_step]
            @test date == DateTime(Date(commodity.date))
        end
        # Each order holds exactly the light commodities of its mapped input commodities
        for (b, bundle) in enumerate(instance.bundles),
            (o, order) in enumerate(bundle.orders)

            sizes = sort(
                reduce(
                    vcat,
                    [
                        fill(c.size, c.quantity) for
                        (k, c) in enumerate(commodities) if c2o[k] == (b, o)
                    ];
                    init=Float64[],
                ),
            )
            @test sort([c.size for c in order.commodities]) == sizes
        end
    end

    instance = Instance(nodes, arcs, commodities, Day(1))
    @test instance.input.nodes === nodes
    @test instance.input.arcs === arcs
    @test instance.input.commodities === commodities
    check_mapping(instance)
    # Same origin and destination: same bundle, different dates: different orders
    @test instance.commodity_to_order[1][1] == instance.commodity_to_order[3][1]
    @test instance.commodity_to_order[1] == instance.commodity_to_order[2]
    @test instance.commodity_to_order[1][2] != instance.commodity_to_order[3][2]
    @test instance.commodity_to_order[1][1] != instance.commodity_to_order[4][1]

    grouped = Instance(nodes, arcs, commodities, Day(1); group_by=c -> c.size > 1.5)
    check_mapping(grouped)
    @test grouped.commodity_to_order[1][1] != grouped.commodity_to_order[2][1]

    multimodal_arcs = [
        arcs;
        Arc(;
            origin_id="A",
            destination_id="B",
            travel_time=Day(2),
            cost=LinearArcCost(0.5),
            info=nothing,
        )
    ]
    multimodal = Instance(
        nodes, multimodal_arcs, commodities, Day(1); allow_multimodal=true
    )
    @test length(multimodal.input.arcs) == 3
    @test multimodal.input.arcs === multimodal_arcs
    check_mapping(multimodal)

    tuple_arcs = [
        ("A", "B", NetworkArc(; travel_time_steps=1, cost=LinearArcCost(1.0))),
        ("C", "B", NetworkArc(; travel_time_steps=1, cost=LinearArcCost(1.0))),
    ]
    tuple_instance = TransportationPlanningOptimization.build_instance(
        nodes, tuple_arcs, commodities, Day(1)
    )
    @test tuple_instance.input.arcs === tuple_arcs
    check_mapping(tuple_instance)

    departure_commodities = [
        Commodity(;
            origin_id=c.origin_id,
            destination_id=c.destination_id,
            size=c.size,
            quantity=c.quantity,
            departure_date=c.date,
            max_delivery_time=c.max_delivery_time,
        ) for c in commodities
    ]
    departure = Instance(nodes, arcs, departure_commodities, Day(1); wrap_time=true)
    @test departure.input.commodities === departure_commodities
    @test departure.bundles[1].orders[1] isa TransportationPlanningOptimization.Order{false}
    check_mapping(departure, departure_commodities)
end

@testset "Node input is converted to NetworkNode" begin
    nodes = [
        Node(; id="A", node_type=:origin, capacity=7, info=:a),
        Node(; id="B", node_type=:destination, info=:b, node_cost=LinearNodeCost(2.0)),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", travel_time=Day(1), cost=LinearArcCost(1.0)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            quantity=1,
            arrival_date=DateTime(2024, 1, 5),
            max_delivery_time=Day(2),
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    @test instance.input.nodes === nodes
    for node in nodes
        network_node = instance.network_graph.graph[node.id]
        @test network_node isa NetworkNode
        for field in (:id, :capacity, :info, :node_cost)
            @test getfield(network_node, field) == getfield(node, field)
        end
    end
    @test Node(; id="X").transit
    @test !Node(; id="X", transit=false).transit
end

@testset "Input links of nodes and arc modes" begin
    for arrival in (false, true)
        @testset "$(arrival ? "arrival" : "departure")_date commodities" begin
            nodes = [
                Node(; id="A", node_type=:origin),
                Node(; id="C", node_type=:origin),
                Node(; id="B", node_type=:destination),
            ]
            mk_arc(o, d, days) = Arc(;
                origin_id=o,
                destination_id=d,
                travel_time=Day(days),
                cost=LinearArcCost(1.0),
            )
            commodities = [
                Commodity(;
                    origin_id=o,
                    destination_id="B",
                    size=1.0,
                    quantity=1,
                    max_delivery_time=Day(3),
                    info=g,
                    (
                        arrival ? (; arrival_date=DateTime(2024, 1, 5)) :
                        (; departure_date=DateTime(2024, 1, 1))
                    )...,
                ) for (o, g) in (("A", "X"), ("C", "Y"))
            ]
            @test eltype(commodities) <: Commodity{arrival}

            @testset "multimodal Arc input, plain and grouped" begin
                arcs = [mk_arc("A", "B", 1), mk_arc("C", "B", 1), mk_arc("A", "B", 2)]
                for kwargs in (NamedTuple(), (; group_by=c -> c.info))
                    instance = Instance(
                        nodes, arcs, commodities, Day(1); allow_multimodal=true, kwargs...
                    )
                    TestFixtures.check_input_links(instance)
                    @test instance.input.arcs === arcs
                    @test [
                        m.input_index for m in instance.network_graph.graph["A", "B"].modes
                    ] == [1, 3]
                    @test instance.network_graph.graph["C", "B"].input_index == 2
                end
            end

            @testset "exact duplicate arc gets two indices" begin
                arcs = [mk_arc("A", "B", 1), mk_arc("A", "B", 1), mk_arc("C", "B", 1)]
                instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
                TestFixtures.check_input_links(instance)
                modes = instance.network_graph.graph["A", "B"].modes
                @test [m.input_index for m in modes] == [1, 2]
            end

            @testset "tuple arcs called directly, user arcs untouched" begin
                mk(c) = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(c))
                tuples = Tuple{String,String,typeof(mk(1.0))}[
                    ("A", "B", mk(1.0)), ("C", "B", mk(2.0)), ("A", "B", mk(3.0))
                ]
                instance = TPO.build_instance(
                    nodes, tuples, commodities, Day(1); allow_multimodal=true
                )
                TestFixtures.check_input_links(instance)
                @test instance.input.arcs === tuples
                @test all(t -> t[3].input_index == 0, tuples)
                @test [
                    m.input_index for m in instance.network_graph.graph["A", "B"].modes
                ] == [1, 3]
            end
        end
    end

    nodes = [
        Node(; id="A", node_type=:origin),
        Node(; id="C", node_type=:origin),
        Node(; id="B", node_type=:destination),
    ]
    mk_cost_arc(o, d, cost) =
        Arc(; origin_id=o, destination_id=d, travel_time=Day(1), cost=cost)
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            quantity=1,
            departure_date=DateTime(2024, 1, 1),
            max_delivery_time=Day(3),
        ),
    ]

    @testset "Union arc type is preserved" begin
        arcs = [
            mk_cost_arc("A", "B", LinearArcCost(1.0)),
            mk_cost_arc("C", "B", BinPackingArcCost(1.0, 10.0)),
        ]
        instance = Instance(nodes, arcs, commodities, Day(1))
        TestFixtures.check_input_links(instance)
        arc = instance.network_graph.graph["A", "B"]
        @test arc isa NetworkArc{Union{LinearArcCost,BinPackingArcCost}}
        @test arc.input_index == 1
    end

    @testset "unknown arc endpoint throws" begin
        lin = LinearArcCost(1.0)
        for bad in (mk_cost_arc("Z", "B", lin), mk_cost_arc("A", "Z", lin))
            arcs = [mk_cost_arc("A", "B", lin), bad]
            @test_throws "has an unknown endpoint" Instance(
                nodes, arcs, commodities, Day(1)
            )
        end
        net_nodes = [
            NetworkNode(; id="A", node_type=:origin),
            NetworkNode(; id="B", node_type=:destination),
        ]
        arc = NetworkArc(; travel_time_steps=1, cost=lin)
        for bad in (("Z", "B", arc), ("A", "Z", arc))
            @test_throws "has an unknown endpoint" NetworkGraph(
                net_nodes, [("A", "B", arc), bad]
            )
        end
    end
end

@testset "Sub-day time steps" begin
    nodes = [
        Node(; id="1", node_type=:origin, capacity=100, info=nothing),
        Node(; id="2", node_type=:destination, capacity=200, info=nothing),
    ]
    arcs = [
        Arc(;
            origin_id="1",
            destination_id="2",
            travel_time=Hour(7),
            cost=LinearArcCost(5.0),
            info=nothing,
        ),
    ]
    mk(date) = Commodity(;
        origin_id="1",
        destination_id="2",
        size=10.0,
        quantity=1,
        departure_date=date,
        max_delivery_time=Hour(24),
    )
    commodities = [mk(DateTime(2024, 1, 1, 1)), mk(DateTime(2024, 1, 1, 13))]
    instance = Instance(nodes, arcs, commodities, Hour(6); wrap_time=true)
    steps = [
        instance.bundles[b].orders[o].time_step for (b, o) in instance.commodity_to_order
    ]
    @test steps == [1, 3]
    dates = instance.time_step_to_date
    @test dates isa Vector{DateTime}
    @test dates[1] == DateTime(2024, 1, 1)
    @test dates[steps[2]] == DateTime(2024, 1, 1, 12)
    @test all(diff(dates) .== Hour(6))
    @test instance.network_graph.graph["1", "2"].travel_time_steps == 1
    @test fieldtype(typeof(instance), :time_step) === Hour
end

@testset "Non-midnight dates keep Day, Week and 30-day order steps" begin
    nodes = [
        Node(; id="1", node_type=:origin, capacity=100, info=nothing),
        Node(; id="2", node_type=:destination, capacity=200, info=nothing),
    ]
    arcs = [
        Arc(;
            origin_id="1",
            destination_id="2",
            travel_time=Day(1),
            cost=LinearArcCost(5.0),
            info=nothing,
        ),
    ]
    # Whole days elapsed since 2024-01-01 at midnight, each date also has a fractional day
    offsets = [0, 6, 13, 14, 30, 35]
    dates = [
        DateTime(2024, 1, 1, 5),
        DateTime(2024, 1, 7, 23, 59),
        DateTime(2024, 1, 14, 18),
        DateTime(2024, 1, 15, 1),
        DateTime(2024, 1, 31, 1),
        DateTime(2024, 2, 5, 12),
    ]
    max_delivery = 30
    # Arrival without wrapping starts max_delivery days earlier, other cases start at 2024-01-01
    for arrival in (true, false), wrap in (true, false), step in (Day(1), Week(1), Day(30))
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=10.0,
                quantity=1,
                (arrival ? :arrival_date : :departure_date) => date,
                max_delivery_time=Day(max_delivery),
            ) for date in dates
        ]
        instance = Instance(nodes, arcs, commodities, step; wrap_time=wrap)
        steps = [
            instance.bundles[b].orders[o].time_step for
            (b, o) in instance.commodity_to_order
        ]
        shift = arrival && !wrap ? max_delivery : 0
        n = Dates.value(Day(step))
        @test steps == fld.(offsets .+ shift, n) .+ 1
    end
end

@testset "Trivial commodities are dropped" begin
    # Days 1 and 30 fall outside the window of the moving commodities in every mode.
    for trivial_id in ("A", "B", "C"),
        arrival in (true, false), wrap in (false, true),
        trivial_day in (1, 10, 30)

        alone = TestFixtures.trivial_instance(nothing; arrival, wrap_time=wrap)
        for trivial_first in (false, true)
            instance = TestFixtures.trivial_instance(
                trivial_id; arrival, wrap_time=wrap, trivial_first, trivial_day
            )
            @test bundle_count(instance) == 1
            @test commodity_count(instance) == 2
            trivial_idx = trivial_first ? 1 : 3
            @test instance.commodity_to_order[trivial_idx] == (0, 0)
            routed = deleteat!(copy(instance.commodity_to_order), trivial_idx)
            @test all(!=((0, 0)), routed)
            @test instance.time_step_to_date == alone.time_step_to_date
            @test instance.time_horizon_length == alone.time_horizon_length
        end
    end
end

@testset "Commodity endpoint validation" begin
    nodes = [
        Node(; id="A", node_type=:origin, capacity=10, info=nothing),
        Node(; id="B", node_type=:destination, capacity=10, info=nothing),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            travel_time=Day(1),
            cost=LinearArcCost(1.0),
            info=nothing,
        ),
    ]
    commodity(o, d) = Commodity(;
        origin_id=o,
        destination_id=d,
        size=1.0,
        arrival_date=DateTime(2024, 1, 10),
        max_delivery_time=Day(4),
    )
    normal = commodity("A", "B")
    for bad in (commodity("A", "Z"), commodity("Z", "B"), commodity("Z", "Z"))
        @test_throws "input commodity 2" Instance(nodes, arcs, [normal, bad], Day(1))
        @test_throws "\"Z\" is not in nodes" Instance(nodes, arcs, [normal, bad], Day(1))
    end
    @test_throws "every input commodity has its origin equal to its destination" Instance(
        nodes, arcs, [commodity("A", "A"), commodity("B", "B")], Day(1)
    )
    @test_throws "commodities is empty" Instance(
        nodes, arcs, Commodity{true,String,Nothing}[], Day(1)
    )
end

@testset "Trivial commodities keep no constraint nor copy" begin
    for (id, extra) in
        (("B", (; forbidden_node_ids=["B"])), ("A", (; forbidden_arcs=[("A", "B")])))
        instance = TestFixtures.trivial_instance(id; trivial_extra=extra)
        @test instance.commodity_to_order[3] == (0, 0)
        @test isempty(only(instance.bundles).forbidden_nodes)
        @test isempty(only(instance.bundles).forbidden_arcs)
    end
    base = TestFixtures.trivial_instance("B"; trivial_extra=(; quantity=3))
    c = base.input.commodities
    instance = Instance(base.input.nodes, base.input.arcs, [c[1], c[3], c[2]], Day(1))
    @test bundle_count(instance) == 1
    @test commodity_count(instance) == 2
    mapping = instance.commodity_to_order
    @test mapping[2] == (0, 0)
    @test Set([mapping[1], mapping[3]]) == Set([(1, 1), (1, 2)])
end
