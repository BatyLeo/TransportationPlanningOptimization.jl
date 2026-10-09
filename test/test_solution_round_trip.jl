using Test
using Dates
using Random
using TransportationPlanningOptimization

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures
using .TestFixtures: check_round_trip, rejects

# Content of every non-empty slot, per time-space edge and slot.
function slot_contents(state)
    return Dict(
        (edge, i) => (slot.commodities, [bin.commodities for bin in slot.bins]) for
        (edge, a) in state.assignments for
        (i, slot) in enumerate(a isa TPO.MultiAssignment ? a.per_mode : [a]) if
        !isempty(slot.commodities)
    )
end

# Number of copies of each commodity per time-space edge and slot.
function slot_counts(state)
    return Dict(
        key => Dict(c => count(==(c), commodities) for c in unique(commodities)) for
        (key, (commodities, _)) in slot_contents(state)
    )
end

@testset "Round trip on leg instances" begin
    # Departure-date and mixed-transit instances are round-tripped by `check_projection` in test_solution.jl.
    trucks = TestFixtures._TRUCK_TRAIN_MODES
    cases = [
        ("arrival date", trucks, 3, (; arrival=true)),
        ("cheapest of two modes", [(10.0, 1, 10), (5.0, 1, 10)], 1, (;)),
    ]
    for (label, modes, days, kwargs) in cases
        @testset "$label" begin
            instance = TestFixtures._leg_instance(modes, days; kwargs...)
            state = greedy_heuristic(instance; show_progress=false)
            check_round_trip(state, instance; same_cost=true)
        end
    end

    @testset "negative offset of a wrapped arrival date" begin
        instance = TestFixtures._leg_instance(
            trucks, 3; arrival=true, wrap_time=true, departure_days=(1, 6)
        )
        state = greedy_heuristic(instance; show_progress=false)
        solution = Solution(state, instance)
        start = instance.time_step_to_date[1]
        @test any(leg.departure < start for route in solution.routes for leg in route)
        check_round_trip(state, instance; same_cost=true)
    end

    @testset "FillThenSpillMode keeps the per-slot copies" begin
        spill = [(10.0, 1, 3), (5.0, 1, 3), (20.0, 2, 100)]
        instance = TestFixtures._leg_instance(
            spill, 3; quantity=2, departure_days=(1, 1), node_cost=LinearNodeCost(2.0)
        )
        state = greedy_heuristic(
            instance; mode_selector=FillThenSpillMode(), show_progress=false
        )
        rebuilt = check_round_trip(state, instance; same_cost=true)
        @test slot_counts(rebuilt) == slot_counts(state)
        @test length(slot_counts(rebuilt)) == 2

        # The rebuilt state can be edited like a greedy one.
        local_search!(rebuilt, instance, FillThenSpillMode(); max_iter=20, time_limit=10.0)
        @test is_feasible(rebuilt, instance)
        rebuilt = SolutionState(Solution(state, instance), instance)
        TPO.remove_bundle_path!(rebuilt, instance, 1)
        @test isempty(slot_contents(rebuilt))
    end
end

@testset "Round trip on an instance without bundles and on solver output" begin
    instance = TestFixtures.tiny_instance()
    filtering = SolutionState(instance)
    filtering.bundle_paths .= [
        [
            instance.travel_time_graph.origin_codes[i],
            instance.travel_time_graph.destination_codes[i],
        ] for i in eachindex(instance.bundles)
    ]
    sub_instance = @test_logs (:info,) match_mode = :any TPO.extract_filtered_instance(
        instance, filtering
    )
    @test bundle_count(sub_instance) == 0
    state = check_round_trip(SolutionState(sub_instance), sub_instance; same_cost=true)
    @test isempty(state.bundle_paths) && isempty(state.assignments)

    # The arcs of tiny pack bins, but first-fit decreasing reproduces the packing of greedy here.
    state = TPO.solve_state(instance; local_search=false, show_progress=false)
    check_round_trip(state, instance; same_cost=true)
end

@testset "Round trip with shortcut nodes in the stored paths" begin
    for (instance, state) in (
        (TestFixtures._leg_instance(TestFixtures._TRUCK_TRAIN_MODES, 3), nothing),
        (
            TestFixtures._leg_instance(TestFixtures._TRUCK_TRAIN_MODES, 3; arrival=true),
            nothing,
        ),
        (TestFixtures.tiny_instance(), TestFixtures.tiny_greedy()),
    )
        state = something(state, greedy_heuristic(instance; show_progress=false))
        @test TestFixtures.add_shortcuts!(state, instance) > 0
        check_round_trip(state, instance; same_cost=true)
    end
end

@testset "The rebuilt state is deterministic" begin
    instance = TestFixtures.small_instance(; wrap_time=false)
    solution = Solution(TestFixtures.small_greedy(; wrap_time=false), instance)
    first_state = SolutionState(solution, instance)
    @test slot_contents(first_state) == slot_contents(SolutionState(solution, instance))
    @test any(!isempty(bins) for (_, bins) in values(slot_contents(first_state)))
end

# Arcs: 1 A->B, 2 B->D, 3 A->C, 4 C->D (1 day each), 5 A->D (2 days), 6 B->A (1 day).
# Commodities arrive at D on January `day` with at most `max_days` days of transit.
# `forbidden` forbids node B and arc (A, C) for the commodities.
function diamond_instance(;
    days=(10,), copies=1, forbidden::Bool=false, max_days=map(_ -> 4, days)
)
    nodes = [
        Node(; id="A", node_type=:origin),
        Node(; id="B", node_type=:other),
        Node(; id="C", node_type=:other),
        Node(; id="D", node_type=:destination),
    ]
    arc(o, d, days) =
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(days))
    arcs = [
        arc("A", "B", 1),
        arc("B", "D", 1),
        arc("A", "C", 1),
        arc("C", "D", 1),
        arc("A", "D", 2),
        arc("B", "A", 1),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="D",
            arrival_date=DateTime(2024, 1, day),
            max_delivery_time=Day(max_days[i]),
            size=1.0,
            forbidden_node_ids=forbidden ? ["B"] : String[],
            forbidden_arcs=forbidden ? [("A", "C")] : Tuple{String,String}[],
        ) for (i, day) in enumerate(days) for _ in 1:copies
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

const DIAMOND_TRANSIT = (1, 1, 1, 1, 2, 1)

# Route of `(arc, departure day)` pairs of the diamond instance.
function route(legs...)
    return [
        TPO.Leg(;
            arc,
            departure=DateTime(2024, 1, day),
            arrival=DateTime(2024, 1, day + DIAMOND_TRANSIT[arc]),
            quantity=1,
        ) for (arc, day) in legs
    ]
end

function rebuild(instance, routes)
    return SolutionState(TPO.Solution(routes, TPO.ArcFlow[]), instance)
end

function edit(leg; kwargs...)
    fields = (; leg.arc, leg.departure, leg.arrival, leg.quantity)
    return TPO.Leg(; merge(fields, NamedTuple(kwargs))...)
end

@testset "Orders of one bundle at different dates share the bundle path" begin
    instance = diamond_instance(; days=(10, 12))
    state = rebuild(instance, [route((5, 8)), route((5, 10))])
    @test is_feasible(state, instance)
    @test Solution(state, instance).routes == [route((5, 8)), route((5, 10))]
    @test length(only(state.bundle_paths)) == 2
end

@testset "Rejected plans" begin
    plain = diamond_instance()
    forbidden = diamond_instance(; forbidden=true)
    direct = route((5, 8))
    # Two commodities of one order, then two orders of one bundle.
    same_order = diamond_instance(; copies=2)
    two_orders = diamond_instance(; days=(10, 12))
    # Three copies split over arcs with transit times of 1 and 2 days.
    split_instance = TestFixtures._leg_instance(
        [(10.0, 1, 10), (5.0, 2, 10), (7.0, 1, 10)], 3; quantity=3
    )
    split_route = [
        TPO.Leg(;
            arc=1, departure=DateTime(2024, 1, 1), arrival=DateTime(2024, 1, 2), quantity=1
        ),
        TPO.Leg(;
            arc=2, departure=DateTime(2024, 1, 1), arrival=DateTime(2024, 1, 3), quantity=2
        ),
    ]
    two_copies = TestFixtures._leg_instance([(1.0, 1, 10)], 3; quantity=2)
    cases = [
        ("has 2 routes for 1", plain, [direct, direct]),
        ("route is empty", plain, [TPO.Leg[]]),
        ("arc index 0 is out of range", plain, [[edit(only(direct); arc=0)]]),
        ("arc index 7 is out of range", plain, [[edit(only(direct); arc=7)]]),
        ("not positive", plain, [[edit(only(direct); quantity=0)]]),
        (
            "exceeds the commodity quantity",
            plain,
            [[edit(only(direct); quantity=typemax(Int))]],
        ),
        ("split across legs from", split_instance, [split_route]),
        ("total quantity of 1", two_copies, [[edit(split_route[1]; arc=1)]]),
        (
            "not on the time grid",
            plain,
            [[edit(only(direct); departure=DateTime(2024, 1, 8, 1))]],
        ),
        ("takes 2", plain, [[edit(only(direct); arrival=DateTime(2024, 1, 11))]]),
        ("commodity origin", plain, [route((4, 9))]),
        ("commodity destination", plain, [route((1, 8))]),
        ("previous leg ends at B", plain, [route((1, 7), (4, 9))]),
        ("legs overlap", plain, [route((1, 9), (2, 9))]),
        ("waiting is only possible before the first leg", plain, [route((1, 7), (2, 9))]),
        ("deadline violation", plain, [route((5, 9))]),
        ("waiting at the destination", plain, [route((5, 7))]),
        # Simple paths take at most 2 of the 4 allowed days, so only a looping route
        # (A -> B -> A -> B -> A -> D) goes beyond the maximum delivery time.
        (
            "maximum delivery time of its commodity group",
            two_orders,
            [direct, route((1, 6), (6, 7), (1, 8), (6, 9), (5, 10))],
        ),
        ("forbidden node B", forbidden, [route((1, 8), (2, 9))]),
        ("forbidden arc", forbidden, [route((3, 8), (4, 9))]),
        ("not elementary", plain, [route((1, 6), (6, 7), (5, 8))]),
        ("do not follow the same path", same_order, [direct, route((1, 8), (2, 9))]),
        ("do not follow the same path", two_orders, [direct, route((1, 10), (2, 11))]),
    ]
    for (fragment, instance, routes) in cases
        @test_throws rejects(fragment) rebuild(instance, routes)
    end
end

@testset "Rejected plans, commodity larger than the bin capacity" begin
    # A plan through the second arc of size-6 commodities, built on a linear twin of the instance.
    modes(second) = [(10.0, 1, 100), (second, 1, 100)]
    linear = TestFixtures._leg_instance(modes(20.0), 3; quantity=1, size=6.0)
    instance = TestFixtures._leg_instance(
        modes(BinPackingArcCost(1.0, 5.0)), 3; quantity=1, size=6.0
    )
    solution = TPO.solve(linear; local_search=false, show_progress=false)
    @test only(only(solution.routes)).arc == 1
    edited = Solution(
        [[edit(only(route); arc=2) for route in solution.routes]], solution.arc_flows
    )
    @test !is_feasible(edited, instance)
    @test_throws rejects("size 6.0 exceeds the bin capacity 5.0 of input arc 2") SolutionState(
        edited, instance
    )
    @test_throws ArgumentError TPO.solve(instance; start=edited, show_progress=false)
end

@testset "Rejected plans, node that routes cannot cross" begin
    # Arcs: 1 A -> B, 2 B -> D, 3 D -> B (1 day each), the route 1, 2, 3, 2 is within the 4 allowed
    # days but crosses the destination D two days before its arrival date.
    nodes = [
        Node(; id="A", node_type=:origin),
        Node(; id="B", node_type=:other),
        Node(; id="D", node_type=:destination),
    ]
    arc(o, d) =
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(1))
    commodity = Commodity(;
        origin_id="A",
        destination_id="D",
        arrival_date=DateTime(2024, 1, 10),
        max_delivery_time=Day(4),
        size=1.0,
    )
    instance = Instance(
        nodes, [arc("A", "B"), arc("B", "D"), arc("D", "B")], [commodity], Day(1)
    )
    leg(a, day) = TPO.Leg(;
        arc=a,
        departure=DateTime(2024, 1, day),
        arrival=DateTime(2024, 1, day + 1),
        quantity=1,
    )
    @test_throws rejects("routes cannot cross at this date") rebuild(
        instance, [[leg(1, 6), leg(2, 7), leg(3, 8), leg(2, 9)]]
    )
end

@testset "Rejected plans, outside the time horizon" begin
    # The horizon is January 9 to 14, the first order may only travel 1 day
    # but the route of the bundle departs 2 days before the order date.
    instance = diamond_instance(; days=(10, 14), max_days=(1, 4))
    @test_throws rejects("outside the time horizon") rebuild(
        instance, [route((5, 8)), route((5, 12))]
    )

    # Departure dates 1 and 4 with 4 and 1 days of transit give the horizon 1 to 5,
    # the 2-day leg of the second order ends on step 6.
    nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(2)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            departure_date=DateTime(2024, 1, day),
            max_delivery_time=Day(days),
            size=1.0,
        ) for (day, days) in ((1, 4), (4, 1))
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    leg(day) = TPO.Leg(;
        arc=1,
        departure=DateTime(2024, 1, day),
        arrival=DateTime(2024, 1, day + 2),
        quantity=1,
    )
    @test_throws rejects("outside the time horizon") rebuild(instance, [[leg(1)], [leg(4)]])
end

@testset "Rejected plans, departure date" begin
    instance = TestFixtures._leg_instance([(1.0, 1, 10)], 3)
    # Commodities depart on January 1 and the arc takes 1 day.
    leg = TPO.Leg(;
        arc=1, departure=DateTime(2024, 1, 1), arrival=DateTime(2024, 1, 2), quantity=2
    )
    @test is_feasible(rebuild(instance, [[leg]]), instance)
    for (fragment, shift) in (("release violation", -1), ("waiting at the origin", 1))
        moved = edit(
            leg; departure=leg.departure + Day(shift), arrival=leg.arrival + Day(shift)
        )
        @test_throws rejects(fragment) rebuild(instance, [[moved]])
    end
end

@testset "Rejected plans, arrival date" begin
    instance = TestFixtures._leg_instance(
        [(1.0, 1, 10)], 3; arrival=true, departure_days=(5,)
    )
    leg = TPO.Leg(;
        arc=1, departure=DateTime(2024, 1, 4), arrival=DateTime(2024, 1, 5), quantity=2
    )
    @test is_feasible(rebuild(instance, [[leg]]), instance)
    for (fragment, shift) in (("deadline violation", 1), ("waiting at the destination", -1))
        moved = edit(
            leg; departure=leg.departure + Day(shift), arrival=leg.arrival + Day(shift)
        )
        @test_throws rejects(fragment) rebuild(instance, [[moved]])
    end
end

@testset "Rejected plans, delivery budget of the bundle" begin
    nodes = [
        Node(; id="O", node_type=:origin),
        Node(; id="D1", node_type=:destination),
        Node(; id="D2", node_type=:destination),
    ]
    arc(d, days) = Arc(;
        origin_id="O", destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(days)
    )
    commodity(d, days) = Commodity(;
        origin_id="O",
        destination_id=d,
        arrival_date=DateTime(2024, 1, 10),
        max_delivery_time=Day(days),
        size=1.0,
    )
    instance = Instance(
        nodes,
        [arc("D1", 1), arc("D1", 2), arc("D2", 1)],
        [commodity("D1", 1), commodity("D2", 3)],
        Day(1);
        allow_multimodal=true,
    )
    leg(arc, days) = TPO.Leg(;
        arc,
        departure=DateTime(2024, 1, 10 - days),
        arrival=DateTime(2024, 1, 10),
        quantity=1,
    )
    @test is_feasible(rebuild(instance, [[leg(1, 1)], [leg(3, 1)]]), instance)
    @test_throws rejects("maximum delivery time of its commodity group") rebuild(
        instance, [[leg(2, 2)], [leg(3, 1)]]
    )

    # In departure-date mode the same check applies.
    instance = TestFixtures._leg_instance([(1.0, 1, 10), (1.0, 3, 10)], 1)
    leg = TPO.Leg(;
        arc=2, departure=DateTime(2024, 1, 1), arrival=DateTime(2024, 1, 4), quantity=2
    )
    @test_throws rejects(
        "the route is longer than the maximum delivery time of its commodity group (A -> B)"
    ) rebuild(instance, [[leg]])
end

@testset "Rejected plans, sub-instance" begin
    instance = @test_logs (:warn, r"1 input arc\(s\) skipped") match_mode = :any TestFixtures.shared_arc_instance(;
        transit=false
    )
    (; solution_state, sub_instance) = solve_filtered(instance; show_progress=false)
    routes = Solution(solution_state, sub_instance).routes
    dropped = findfirst(==((0, 0)), sub_instance.commodity_to_order)
    kept = findfirst(!=((0, 0)), sub_instance.commodity_to_order)
    @test isempty(routes[dropped]) && !isempty(routes[kept])
    @test is_feasible(rebuild(sub_instance, routes), sub_instance)

    # Input arc 1 (A -> B) is dropped with node B.
    with(k, legs) = [i == k ? legs : r for (i, r) in enumerate(routes)]
    cases = [
        ("dropped by the instance", with(dropped, routes[kept])),
        ("has no arc in the instance", with(kept, [edit(routes[kept][1]; arc=1)])),
    ]
    for (fragment, plan) in cases
        @test_throws rejects(fragment) rebuild(sub_instance, plan)
    end
end

@testset "Frozen local search and in-place removal on a rebuilt state" begin
    packed = TestFixtures._leg_instance(
        [(BinPackingArcCost(10.0, 3), 1, 100)], 3; quantity=5, departure_days=(1, 2)
    )
    small = TestFixtures.small_instance(; wrap_time=false)
    cases = [
        (small, TestFixtures.small_greedy(; wrap_time=false)),
        (TestFixtures.tiny_instance(), TestFixtures.tiny_greedy()),
        (packed, greedy_heuristic(packed; show_progress=false)),
    ]
    function arc_costs_match(s)
        return all(sl.arc_cost ≈ 10.0 * length(sl.bins) for sl in values(s.assignments))
    end
    for (instance, state) in cases
        rebuild() = SolutionState(Solution(state, instance), instance)
        rebuilt = rebuild()
        start = cost(rebuilt)
        res = local_search!(rebuilt, instance; max_iter=100, rng=Random.MersenneTwister(1))
        @test is_feasible(rebuilt, instance)
        instance === packed && @test arc_costs_match(rebuilt)
        @test start - res.saved ≈ cost(rebuilt)
        instance === small && @test res.saved > 0

        rebuilt = rebuild()
        path = copy(rebuilt.bundle_paths[1])
        bins_before = sum(length(bins) for (_, (_, bins)) in slot_contents(rebuilt); init=0)
        @test bins_before > 0
        TPO.remove_bundle_path!(rebuilt, instance, 1)
        TPO.add_bundle_path!(rebuilt, instance, 1, path)
        @test is_feasible(rebuilt, instance)
        @test all(all(!isempty, bins) for (_, (_, bins)) in slot_contents(rebuilt))
        instance === packed && @test arc_costs_match(rebuilt)
    end
end

@testset "Trivial commodities have an empty route" begin
    for trivial_id in ("A", "B", "C"), arrival in (true, false)
        alone = TestFixtures.trivial_instance(nothing; arrival)
        instance = TestFixtures.trivial_instance(trivial_id; arrival)
        solution = solve(instance; show_progress=false, time_limit=2.0)
        @test cost(solution) ≈ cost(solve(alone; show_progress=false, time_limit=2.0))
        @test isempty(solution.routes[end])
        @test !isempty(solution.routes[1])
        state = SolutionState(solution, instance)
        @test is_feasible(state, instance; verbose=true)
        @test is_feasible(solution, instance)
        @test Solution(solution.routes, instance).routes == solution.routes
        routes = [solution.routes[1], solution.routes[2], solution.routes[1]]
        @test_throws rejects("dropped by the instance") Solution(routes, instance)
    end
end
