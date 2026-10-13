using Test
using Dates
using Random
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# A->B has a truck and a slower cheaper train (multi-modal leg). F (A->B) is a
# direct path and gets filtered out, K (A->D) is kept and routes through B.
function multimodal_instance()
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="D")]
    truck = Arc(;
        origin_id="A", destination_id="B", cost=LinearArcCost(2.0), travel_time=Day(1)
    )
    train = Arc(;
        origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(2)
    )
    onward = Arc(;
        origin_id="B", destination_id="D", cost=LinearArcCost(1.0), travel_time=Day(1)
    )
    direct = Arc(;
        origin_id="A", destination_id="D", cost=LinearArcCost(10.0), travel_time=Day(1)
    )
    commodity(dst, max_days) = Commodity(;
        origin_id="A",
        destination_id=dst,
        quantity=2,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(max_days),
        size=1.0,
    )
    return Instance(
        nodes,
        [truck, train, onward, direct],
        [commodity("B", 1), commodity("D", 3)],
        Day(1);
        allow_multimodal=true,
    )
end

const LS = (; time_limit=60.0, max_iter=200)

@testset "solve without local search equals the hand-chained pipeline" begin
    instance = TestFixtures.small_instance()
    sol = TPO.solve_state(instance; local_search=false, show_progress=false)

    @test all(!isempty, sol.bundle_paths)
    @test TPO.is_feasible(sol, instance; verbose=true)
    @test TPO.cost(sol) ≈ TPO.cost(TPO.SolutionState(sol.bundle_paths, instance))

    result = TPO.solve_filtered(instance; show_progress=false)
    chained = TPO.merge_solutions(
        result.filtering_state, result.solution_state, instance, result.sub_instance
    )
    @test sol.bundle_paths == chained.bundle_paths
    @test TPO.cost(sol) ≈ TPO.cost(chained)
end

@testset "solve with local search equals the hand-chained pipeline" begin
    instance = TestFixtures.small_instance()
    sol = TPO.solve_state(instance; LS..., rng=MersenneTwister(0), show_progress=false)
    @test TPO.is_feasible(sol, instance; verbose=true)

    result = TPO.solve_filtered(instance; show_progress=false)
    TPO.local_search!(
        result.solution_state, result.sub_instance; LS..., rng=MersenneTwister(0)
    )
    chained = TPO.merge_solutions(
        result.filtering_state, result.solution_state, instance, result.sub_instance
    )
    @test sol.bundle_paths == chained.bundle_paths
    @test TPO.cost(sol) ≈ TPO.cost(chained)
end

@testset "solve with refine_two_node equals the hand-chained pipeline" begin
    instance = TestFixtures.small_instance()
    sol = TPO.solve_state(
        instance; LS..., rng=MersenneTwister(0), refine_two_node=true, show_progress=false
    )
    @test TPO.is_feasible(sol, instance; verbose=true)

    result = TPO.solve_filtered(instance; show_progress=false)
    TPO.local_search!(
        result.solution_state,
        result.sub_instance;
        LS...,
        rng=MersenneTwister(0),
        refine_two_node=true,
    )
    chained = TPO.merge_solutions(
        result.filtering_state, result.solution_state, instance, result.sub_instance
    )
    @test sol.bundle_paths == chained.bundle_paths
    @test TPO.cost(sol) ≈ TPO.cost(chained)

    # The default (false) differs on this fixture, so the keyword is really forwarded.
    plain = TPO.solve_state(instance; LS..., rng=MersenneTwister(0), show_progress=false)
    @test plain.bundle_paths != sol.bundle_paths
end

@testset "solve on a non-wrapping instance is feasible" begin
    instance = TestFixtures.small_instance(; wrap_time=false)
    sol = TPO.solve_state(instance; time_limit=5.0, max_iter=50, show_progress=false)
    @test TPO.is_feasible(sol, instance; verbose=true)
end

@testset "solve keeps the filtering path of a filtered bundle (departure mode)" begin
    instance = TestFixtures.shared_arc_instance()
    filtering_solution = TPO.lower_bound_filtering(instance; show_progress=false)
    sol = TPO.solve_state(instance; time_limit=1.0, max_iter=50, show_progress=false)

    @test TPO.is_feasible(sol, instance; verbose=true)
    filtered = findfirst(
        p -> TPO._direct_arc_position(instance.index_cache, p) != 0,
        filtering_solution.bundle_paths,
    )
    @test !isnothing(filtered)
    @test sol.bundle_paths[filtered] == filtering_solution.bundle_paths[filtered]
end

@testset "solve when every bundle is filtered out" begin
    nodes = [Node(; id="A"), Node(; id="B")]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(1)
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
    filtering_solution = TPO.lower_bound_filtering(instance; show_progress=false)

    sol = @test_logs (:info, r"sub-instance is empty") match_mode = :any TPO.solve_state(
        instance; show_progress=false
    )
    @test sol.bundle_paths == filtering_solution.bundle_paths
    @test TPO.is_feasible(sol, instance; verbose=true)
end

@testset "solve on a multi-modal instance keeps a bundle and is feasible" begin
    instance = multimodal_instance()
    sub_instance = TPO.solve_filtered(instance; show_progress=false).sub_instance
    @test bundle_count(sub_instance) > 0

    sol = TPO.solve_state(instance; time_limit=2.0, max_iter=100, show_progress=false)
    @test TPO.is_feasible(sol, instance; verbose=true)
end

@testset "solve with filtering=false equals construction plus local search" begin
    instance = TestFixtures.small_instance()
    sol = TPO.solve_state(
        instance; filtering=false, LS..., rng=MersenneTwister(0), show_progress=false
    )
    @test TPO.is_feasible(sol, instance; verbose=true)

    chained = TPO.mix_greedy_heuristic(instance; show_progress=false)
    TPO.local_search!(chained, instance; LS..., rng=MersenneTwister(0))
    @test TPO.cost(sol) ≈ TPO.cost(chained)
    @test sol.bundle_paths == chained.bundle_paths
end

@testset "solve returns the Solution of solve_state" begin
    instance = TestFixtures.small_instance()
    kwargs = (; LS..., show_progress=false)
    solution = TPO.solve(instance; kwargs..., rng=MersenneTwister(0))
    solution_state = TPO.solve_state(instance; kwargs..., rng=MersenneTwister(0))
    expected = Solution(solution_state, instance)

    @test solution isa Solution
    @test solution.routes == expected.routes
    @test TestFixtures.flows_match(solution.arc_flows, expected.arc_flows)
    @test cost(solution) ≈ cost(solution_state)
    # solve uses CheapestMode, which never splits an order across modes, so every leg carries the full quantity.
    @test all(enumerate(instance.input.commodities)) do (k, commodity)
        route = solution.routes[k]
        !isempty(route) && all(leg -> leg.quantity == commodity.quantity, route)
    end
    @test is_feasible(solution, instance; verbose=true)
end

@testset "solve with a warm start" begin
    instance = TestFixtures.small_instance()
    kwargs = (; time_limit=60.0, max_iter=50, show_progress=false, rng=MersenneTwister(0))
    # A locally improved start differs from the plan of the default construction.
    start_state = TPO.solve_state(
        instance; max_iter=500, rng=MersenneTwister(1), show_progress=false
    )
    start = Solution(start_state, instance)
    # Relies on 500 local search iterations with seed 1 changing at least one route on small.
    @test start.routes !=
        TPO.solve(instance; local_search=false, show_progress=false).routes
    start_cost = cost(SolutionState(start, instance))

    improved = TPO.solve(instance; start, kwargs...)
    @test is_feasible(improved, instance; verbose=true)
    @test cost(improved) <= start_cost + 1e-6

    same = TPO.solve(instance; start, local_search=false, show_progress=false)
    @test same.routes == start.routes

    state = start_state
    paths, state_cost = deepcopy(state.bundle_paths), cost(state)
    result = TPO.solve_state(instance; start=state, kwargs...)
    @test result !== state
    @test result.bundle_paths !== state.bundle_paths
    @test result.assignments !== state.assignments
    @test is_feasible(result, instance)
    @test is_feasible(state, instance)
    @test state.bundle_paths == paths
    @test cost(state) == state_cost
    @test cost(result) <= state_cost + 1e-6
end

@testset "solve rejects a start that is unrepresentable or infeasible" begin
    instance = TestFixtures.shared_arc_instance()
    start = TPO.solve(instance; local_search=false, show_progress=false)
    (; empty_route, overloaded) = TestFixtures.shared_arc_bad_plans(start)
    @test_throws ArgumentError TPO.solve(instance; start=empty_route, show_progress=false)

    @test !is_feasible(SolutionState(overloaded, instance), instance)
    @test_throws ArgumentError TPO.solve(instance; start=overloaded, show_progress=false)
end

@testset "solve rebuilds the merged state with mode_selector" begin
    # Two modes with the same travel time: a cheap one of capacity 1 and an expensive one.
    # The direct bundle is fixed by filtering, then rebuilt by the merge.
    modes = [(5.0, 1, 1), (10.0, 1, 100)]
    instance = TestFixtures._leg_instance(modes, 3; quantity=3)
    kwargs = (; LS..., rng=MersenneTwister(0), show_progress=false)

    spill = TPO.solve(instance; mode_selector=FillThenSpillMode(), kwargs...)
    @test is_feasible(spill, instance; verbose=true)
    @test sort([f.volume for f in spill.arc_flows]) == [1.0, 2.0]
    @test cost(spill) ≈ 1 * 5 + 2 * 10

    cheapest = TPO.solve(instance; kwargs...)
    @test is_feasible(cheapest, instance; verbose=true)
    @test [f.volume for f in cheapest.arc_flows] == [3.0]
    @test cost(cheapest) ≈ 3 * 10

    unfiltered = TPO.solve(
        instance; mode_selector=FillThenSpillMode(), filtering=false, kwargs...
    )
    @test is_feasible(unfiltered, instance; verbose=true)
    @test sort([f.volume for f in unfiltered.arc_flows]) == [1.0, 2.0]
    @test cost(unfiltered) ≈ 1 * 5 + 2 * 10
end

@testset "solve with FillThenSpillMode splits a bundle over two same-transit modes" begin
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="D")]
    arc(o, d, c, cap=typemax(Int)) = Arc(;
        origin_id=o,
        destination_id=d,
        cost=LinearArcCost(c),
        travel_time=Day(1),
        capacity=cap,
    )
    arcs = [
        arc("A", "B", 1.0, 2),
        arc("A", "B", 3.0, 100),
        arc("B", "D", 1.0),
        arc("A", "D", 10.0),
    ]
    commodity = Commodity(;
        origin_id="A",
        destination_id="D",
        quantity=4,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(3),
        size=1.0,
    )
    instance = Instance(nodes, arcs, [commodity], Day(1); allow_multimodal=true)
    for filtering in (true, false)
        sol = TPO.solve(
            instance;
            mode_selector=FillThenSpillMode(),
            filtering,
            LS...,
            rng=MersenneTwister(0),
            show_progress=false,
        )
        @test is_feasible(sol, instance; verbose=true)
        @test cost(sol) ≈ 12.0
        ab = filter(f -> f.arc in (1, 2), sol.arc_flows)
        @test sort([f.arc for f in ab]) == [1, 2]
        @test [f.volume for f in ab] == [2.0, 2.0]
        @test only(filter(f -> f.arc == 3, sol.arc_flows)).volume == 4.0
    end
end

@testset "solve_state is feasible on tight multi-modal capacities" begin
    arm2 = TestFixtures.lb_arm2_instance()
    fragmented = TestFixtures.fragmented_modes_instance()
    for selector in (CheapestMode(), FillThenSpillMode()), filtering in (true, false)
        for instance in (arm2, fragmented)
            kwargs = (; mode_selector=selector, filtering, show_progress=false)
            construction = TPO.solve_state(instance; kwargs..., local_search=false)
            @test TPO.is_feasible(construction, instance)
            sol = TPO.solve_state(instance; kwargs..., time_limit=2.0, max_iter=100)
            @test TPO.is_feasible(sol, instance)
            @test TPO.cost(sol) <= TPO.cost(construction)
        end
    end
end

@testset "solve with filtering=false and FillThenSpillMode stays feasible on a jointly priced batch" begin
    instance = TestFixtures.joint_batch_instance()
    solution = TPO.solve(
        instance;
        filtering=false,
        mode_selector=FillThenSpillMode(),
        time_limit=2.0,
        max_iter=200,
        show_progress=false,
    )
    @test TPO.is_feasible(TPO.SolutionState(solution, instance), instance; verbose=true)
end
