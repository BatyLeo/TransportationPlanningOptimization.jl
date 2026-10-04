using Test
using CSV
using DataFrames
using Dates
using MetaGraphsNext
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.MultiCommodityFlow

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# Project `sol` and run both checks.
function check_projection(sol, instance; reservations::Bool=false)
    ns = Solution(sol, instance)
    TestFixtures.check_flows(ns, sol)
    TestFixtures.check_routes(ns, sol, instance; reservations)
    return ns
end

@testset "Inbound instances, arrival date, wrap_time on and off" begin
    for name in ("tiny", "small"), wrap_time in (true, false)
        instance = TestFixtures._instance(name, wrap_time)
        sol = TestFixtures._greedy(name, wrap_time)
        ns = check_projection(sol, instance)
        name == "small" && @test any(f -> f.node_cost > 0, ns.arc_flows)
        @test any(c -> c.quantity > 1, instance.input.commodities)
        @test sum(length, ns.routes) >= length(instance.input.commodities)
    end
    @test occursin(
        "Solution(commodities=",
        sprint(
            show, check_projection(TestFixtures.tiny_greedy(), TestFixtures.tiny_instance())
        ),
    )
end

@testset "Departure date instances" begin
    for (wrap_time, departure_days) in ((false, (1,)), (true, (1, 6)))
        instance = TestFixtures._leg_instance(
            TestFixtures._TRUCK_TRAIN_MODES, 3; departure_days, wrap_time
        )
        check_projection(greedy_heuristic(instance; show_progress=false), instance)
    end
end

@testset "FillThenSpillMode splits equal copies across modes by count" begin
    modes = [(10.0, 1, 3), (5.0, 1, 3), (20.0, 2, 100)]
    instance = TestFixtures._leg_instance(modes, 3; quantity=2, departure_days=(1, 1))
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode(), show_progress=false)
    ns = check_projection(sol, instance)
    @test [(f.arc, f.volume) for f in ns.arc_flows] == [(1, 1.0), (2, 3.0)]
    @test sum(l.quantity for l in ns.routes[1]) == 2
    @test sum(l.quantity for l in ns.routes[2]) == 2
    @test sum(f.node_cost for f in ns.arc_flows) == 0.0
    @test any(r -> length(r) == 2, ns.routes)
end

@testset "Mixed transit times map each leg to its mode" begin
    modes = [(10.0, 1, 10), (5.0, 2, 10), (7.0, 1, 10)]
    for (days, wrap_time, departure_days) in
        ((1, false, (1,)), (3, false, (1,)), (3, true, (1, 6)))
        instance = TestFixtures._leg_instance(modes, days; departure_days, wrap_time)
        check_projection(greedy_heuristic(instance; show_progress=false), instance)
    end
end

@testset "Multicommodity flow instance without time dimension" begin
    dow = """
    MULTIGEN.DAT:
       3   3   2
       1   3   1   5   1   1   1
       1   2   3   100   10   1   2
       2   3   3   100   10   1   3
       1   3   10
       2   3   5
    """
    for network_design in (true, false)
        instance = MultiCommodityFlow.parse_canad_instance(IOBuffer(dow); network_design)
        sol = greedy_heuristic(instance; show_progress=false)
        ns = check_projection(sol, instance)
        @test length(ns.routes[1]) == 2
    end
end

@testset "Sub-day time steps keep the time of day" begin
    nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Hour(7)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            arrival_date=DateTime(2024, 1, 2, 13),
            max_delivery_time=Hour(24),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Hour(6))
    ns = check_projection(greedy_heuristic(instance; show_progress=false), instance)
    # The 13:00 date is floored to 12:00 and the 7 hours transit to 6 hours.
    leg = TPO.Leg(;
        arc=1,
        departure=DateTime(2024, 1, 2, 6),
        arrival=DateTime(2024, 1, 2, 12),
        quantity=1,
    )
    @test ns.routes == [[leg]]
    @test only(ns.arc_flows).departure == DateTime(2024, 1, 2, 6)
end

@testset "Sub-instance: dropped commodities, reservations only in flows" begin
    instance = TestFixtures.shared_arc_instance()
    (; solution, sub_instance, filtering_solution) = solve_filtered(
        instance; show_progress=false
    )
    @test any(==((0, 0)), sub_instance.commodity_to_order)
    ns = check_projection(solution, sub_instance; reservations=true)
    dropped = findall(==((0, 0)), sub_instance.commodity_to_order)
    @test all(k -> isempty(ns.routes[k]), dropped)
    @test any(!isempty, ns.routes)
    # The reserved commodity loads its direct arc without belonging to any route.
    @test any(f -> f.arc == 1 && f.volume == 3.0, ns.arc_flows)
    @test sum(length, ns.routes) == 2
end

@testset "Dirty bins keep n_bins consistent with the arc cost" begin
    modes = [(BinPackingArcCost(10.0, 2), 1, 10)]
    instance = TestFixtures._leg_instance(modes, 1; quantity=4)
    sol = greedy_heuristic(instance; show_progress=false)
    flow = only(Solution(sol, instance).arc_flows)
    @test (flow.n_bins, flow.volume) == (2, 4.0)

    slot = only(values(sol.assignments))
    pop!(slot.commodities)
    pop!(slot.commodities)
    slot.total_size -= 2
    TPO._update_cost_skip_bins!(slot, only(instance.input.arcs).cost)
    @test slot.bins_dirty
    @test length(slot.bins) == 2
    ns = Solution(sol, instance)
    TestFixtures.check_flows(ns, sol)
    flow = only(ns.arc_flows)
    @test flow.n_bins == 1
    @test flow.n_bins * 10.0 ≈ flow.arc_cost
end

# Extend every path with the chain of shortcut nodes that the travel-time graph allows.
function add_shortcuts!(sol, instance)
    g = instance.travel_time_graph.graph
    arrival = TPO.is_date_arrival(instance.travel_time_graph)
    added = 0
    for path in sol.bundle_paths
        id, τ = MetaGraphsNext.label_for(g, arrival ? first(path) : last(path))
        while haskey(g, (id, τ + 1))
            τ += 1
            code = MetaGraphsNext.code_for(g, (id, τ))
            arrival ? pushfirst!(path, code) : push!(path, code)
            added += 1
        end
    end
    return added
end

@testset "Stored paths with shortcut nodes give the same projection" begin
    for (instance, sol) in (
        (TestFixtures._leg_instance(TestFixtures._TRUCK_TRAIN_MODES, 3), nothing),
        (TestFixtures.tiny_instance(), TestFixtures.tiny_greedy()),
    )
        sol = something(sol, greedy_heuristic(instance; show_progress=false))
        expected = Solution(sol, instance)
        @test add_shortcuts!(sol, instance) > 0
        ns = Solution(sol, instance)
        @test ns.routes == expected.routes
        @test ns.arc_flows == expected.arc_flows
    end
end

@testset "Multi-modal node cost sits on the first non-empty mode row" begin
    node_cost = LinearNodeCost(2.0)
    modes = [(10.0, 1, 3), (5.0, 1, 3), (20.0, 2, 100)]
    instance = TestFixtures._leg_instance(modes, 3; quantity=5, node_cost)
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode(), show_progress=false)
    ns = check_projection(sol, instance)
    @test [(f.arc, f.volume, f.node_cost) for f in ns.arc_flows] == [(1, 2.0, 10.0), (2, 3.0, 0.0)]

    modes = [(10.0, 1, 10), (5.0, 1, 10)]
    instance = TestFixtures._leg_instance(modes, 1; quantity=2, node_cost)
    sol = greedy_heuristic(instance; show_progress=false)
    ns = check_projection(sol, instance)
    @test [(f.arc, f.volume, f.node_cost) for f in ns.arc_flows] == [(2, 2.0, 4.0)]
end

@testset "Mismatched solutions throw or project to nothing" begin
    instance = TestFixtures._leg_instance(TestFixtures._TRUCK_TRAIN_MODES, 1)
    sol = greedy_heuristic(instance; show_progress=false)
    empty!(sol.assignments)
    @test isempty(Solution(sol, instance).arc_flows)

    modes = [(10.0, 1, 3), (5.0, 1, 3)]
    instance = TestFixtures._leg_instance(modes, 1; quantity=2)
    sol = greedy_heuristic(instance; show_progress=false)
    only(values(sol.assignments)).per_mode[1].commodities |> empty!
    only(values(sol.assignments)).per_mode[2].commodities |> empty!
    @test_throws ArgumentError Solution(sol, instance)

    # A multi-modal assignment with a wrong number of slots would put the load on the wrong arc.
    sol = greedy_heuristic(instance; show_progress=false)
    (edge, m), = collect(sol.assignments)
    sol.assignments[edge] = TPO.MultiAssignment(m.per_mode[2:2], m.node_cost)
    @test_throws ArgumentError Solution(sol, instance)
    empty!(sol.bundle_paths[1])
    @test_throws ArgumentError Solution(sol, instance)

    # An assignment type that does not match its edge arc.
    instance = TestFixtures._leg_instance(TestFixtures._TRUCK_TRAIN_MODES, 1)
    sol = greedy_heuristic(instance; show_progress=false)
    edge, single = only(sol.assignments)
    sol.assignments[edge] = TPO.MultiAssignment([single, single], 0.0)
    empty!(sol.bundle_paths[1])
    @test_throws ArgumentError Solution(sol, instance)
end

@testset "Routes and arc flows are Tables.jl compatible" begin
    ns = check_projection(TestFixtures.tiny_greedy(), TestFixtures.tiny_instance())
    flows = DataFrame(ns.arc_flows)
    @test names(flows) == collect(string.(fieldnames(TPO.ArcFlow)))
    @test nrow(flows) == length(ns.arc_flows)
    route = ns.routes[findfirst(!isempty, ns.routes)]
    legs = DataFrame(route)
    @test names(legs) == collect(string.(fieldnames(TPO.Leg)))
    @test nrow(legs) == length(route)
    flat = DataFrame([
        (; commodity=k, leg.arc, leg.departure, leg.arrival, leg.quantity) for
        (k, route_legs) in enumerate(ns.routes) for leg in route_legs
    ])
    @test nrow(flat) == sum(length, ns.routes)
    @test names(flat) == ["commodity", "arc", "departure", "arrival", "quantity"]
    empty_flat = DataFrame([
        (; commodity=k, leg.arc, leg.departure, leg.arrival, leg.quantity) for
        (k, route_legs) in
        enumerate(TPO.Solution([TPO.Leg[] for _ in 1:3], TPO.ArcFlow[]).routes) for
        leg in route_legs
    ])
    @test nrow(empty_flat) == 0
    @test names(empty_flat) == ["commodity", "arc", "departure", "arrival", "quantity"]
    io = IOBuffer()
    CSV.write(io, ns.arc_flows)
    @test nrow(CSV.read(IOBuffer(take!(io)), DataFrame)) == length(ns.arc_flows)
end
