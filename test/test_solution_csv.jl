using Test
using Dates
using Random
using TransportationPlanningOptimization

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures
using .TestFixtures: flows_match, rejects

# Write `solution` to a temporary file, read it back and return the result with the file lines.
function write_and_read(solution, instance)
    path = joinpath(mktempdir(), "solution.csv")
    @test write_solution_csv(path, solution) == path
    return read_solution_csv(path, instance), readlines(path)
end

# Read the file made of `lines`.
function read_lines(lines, instance)
    path = joinpath(mktempdir(), "edited.csv")
    write(path, join(lines, "\n") * "\n")
    return read_solution_csv(path, instance)
end

@testset "Written columns and tiny inbound" begin
    for wrap_time in (false, true)
        instance = TestFixtures._instance("tiny", wrap_time)
        solution = Solution(TestFixtures._greedy("tiny", wrap_time), instance)
        back, lines = write_and_read(solution, instance)
        @test lines[1] == "commodity,leg,arc,departure,arrival,quantity"
        @test length(lines) == 1 + sum(length, solution.routes)
        @test back.routes == solution.routes
        @test is_feasible(back, instance)
        # Bins are repacked, so the cost is compared with the in-memory rebuild.
        @test cost(back) ≈ cost(Solution(solution.routes, instance))
        @test flows_match(back.arc_flows, Solution(solution.routes, instance).arc_flows)
    end
end

@testset "Linear costs keep the flows" begin
    instance = TestFixtures._leg_instance(TestFixtures._TRUCK_TRAIN_MODES, 3; quantity=3)
    solution = Solution(greedy_heuristic(instance; show_progress=false), instance)
    back, _ = write_and_read(solution, instance)
    @test back.routes == solution.routes
    @test cost(back) ≈ cost(solution)
    @test flows_match(back.arc_flows, solution.arc_flows)
    # Solution(routes, instance) rebuilds the same plan without a file.
    rebuilt = Solution(solution.routes, instance)
    @test rebuilt.routes == solution.routes
    @test flows_match(rebuilt.arc_flows, solution.arc_flows)
    @test cost(rebuilt) ≈ cost(solution)
end

@testset "Dates round trip exactly" begin
    @testset "Hour(6) time step" begin
        nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]
        arcs = [
            Arc(;
                origin_id="A",
                destination_id="B",
                cost=LinearArcCost(1.0),
                travel_time=Hour(7),
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
        solution = Solution(greedy_heuristic(instance; show_progress=false), instance)
        back, lines = write_and_read(solution, instance)
        @test back.routes == solution.routes
        @test back.routes[1][1].departure == DateTime(2024, 1, 2, 6)
        @test occursin("2024-01-02T06:00:00", lines[2])
    end

    @testset "wrapped dates before the start date" begin
        instance = TestFixtures._leg_instance(
            TestFixtures._TRUCK_TRAIN_MODES,
            3;
            arrival=true,
            wrap_time=true,
            departure_days=(1, 6),
        )
        solution = Solution(greedy_heuristic(instance; show_progress=false), instance)
        start = instance.time_step_to_date[1]
        @test any(leg.departure < start for route in solution.routes for leg in route)
        back, _ = write_and_read(solution, instance)
        @test back.routes == solution.routes
    end
end

@testset "FillThenSpillMode with split legs" begin
    spill = [(10.0, 1, 3), (5.0, 1, 3), (20.0, 2, 100)]
    instance = TestFixtures._leg_instance(
        spill, 3; quantity=2, departure_days=(1, 1), node_cost=LinearNodeCost(2.0)
    )
    state = greedy_heuristic(
        instance; mode_selector=FillThenSpillMode(), show_progress=false
    )
    solution = Solution(state, instance)
    @test any(length(route) > 1 for route in solution.routes)
    back, _ = write_and_read(solution, instance)
    @test back.routes == solution.routes
    @test cost(back) ≈ cost(solution)
end

@testset "Dropped commodities and empty solutions" begin
    instance = TestFixtures.shared_arc_instance()
    (; solution_state, sub_instance) = solve_filtered(instance; show_progress=false)
    solution = Solution(solution_state, sub_instance)
    @test any(isempty, solution.routes)
    back, lines = write_and_read(solution, sub_instance)
    @test back.routes == solution.routes
    @test length(lines) == 1 + sum(length, solution.routes)

    # A row for a dropped commodity is rejected by the reverse conversion.
    dropped = findfirst(==((0, 0)), sub_instance.commodity_to_order)
    kept = findfirst(!=((0, 0)), sub_instance.commodity_to_order)
    row = lines[findfirst(startswith("$kept,"), lines)]
    @test_throws rejects("input commodity $dropped: the commodity is dropped") read_lines(
        [lines; replace(row, r"^\d+," => "$dropped,")], sub_instance
    )

    # No legs at all: the file only has a header.
    instance = TestFixtures.tiny_instance()
    filtering = SolutionState(instance)
    filtering.bundle_paths .= [
        [
            instance.travel_time_graph.origin_codes[i],
            instance.travel_time_graph.destination_codes[i],
        ] for i in eachindex(instance.bundles)
    ]
    empty_instance = @test_logs (:info,) match_mode = :any TPO.extract_filtered_instance(
        instance, filtering
    )
    solution = Solution(SolutionState(empty_instance), empty_instance)
    back, lines = write_and_read(solution, empty_instance)
    @test lines == ["commodity,leg,arc,departure,arrival,quantity"]
    @test all(isempty, back.routes)
    @test back.routes == solution.routes
end

@testset "Row order does not matter" begin
    instance = TestFixtures._instance("tiny", false)
    solution = Solution(TestFixtures._greedy("tiny", false), instance)
    _, lines = write_and_read(solution, instance)
    shuffled = [lines[1]; shuffle(MersenneTwister(1), lines[2:end])]
    @test shuffled != lines
    @test read_lines(shuffled, instance).routes == solution.routes
end

@testset "Structural errors" begin
    instance = TestFixtures._leg_instance(
        [(1.0, 1, 10), (1.0, 3, 10)], 3; quantity=2, departure_days=(1, 2)
    )
    solution = Solution(greedy_heuristic(instance; show_progress=false), instance)
    _, lines = write_and_read(solution, instance)
    header, rows = lines[1], lines[2:end]
    @test length(rows) == 2

    without_arrival(line) = join(deleteat!(split(line, ","), 5), ",")
    @test_throws rejects("missing columns arrival") read_lines(
        without_arrival.(lines), instance
    )
    @test_throws rejects("row 2: commodity 3 is outside 1:2") read_lines(
        [header, rows[1], replace(rows[2], r"^2," => "3,")], instance
    )
    @test_throws rejects("row 1: leg number 0 of commodity 1 is not positive") read_lines(
        [header, replace(rows[1], r"^1,1," => "1,0,"), rows[2]], instance
    )
    @test_throws rejects("row 2: duplicate leg 1 of commodity 1") read_lines(
        [header, rows[1], replace(rows[2], r"^2," => "1,")], instance
    )
    @test_throws rejects("row 2: commodity 2 has no leg 1") read_lines(
        [header, rows[1], replace(rows[2], r"^2,1," => "2,2,")], instance
    )
    @test_throws rejects("row 1: missing or unparsable value in column quantity") read_lines(
        [header, replace(rows[1], r",\d+$" => ","), rows[2]], instance
    )
    @test_throws rejects("row 2: missing or unparsable value in column departure") read_lines(
        [
            header,
            rows[1],
            replace(rows[2], r"20\d\d-\d\d-\d\dT[\d:]+" => "tomorrow", count=1),
        ],
        instance,
    )
    # A structurally valid file that is not a valid plan.
    @test_throws ArgumentError read_lines(
        [header, replace(rows[1], r",\d+$" => ",9"), rows[2]], instance
    )
end

@testset "Solution(routes, instance)" begin
    instance = TestFixtures._leg_instance(TestFixtures._TRUCK_TRAIN_MODES, 3; quantity=3)
    solution = Solution(greedy_heuristic(instance; show_progress=false), instance)
    # Routes only, flows are rebuilt.
    rebuilt = Solution(solution.routes, instance)
    @test rebuilt.routes == solution.routes
    @test flows_match(rebuilt.arc_flows, solution.arc_flows)
    @test is_feasible(rebuilt, instance)
    @test_throws ArgumentError Solution([TPO.Leg[] for _ in solution.routes], instance)
end
