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
    nodes = [
        Node(; id="A", node_type=:origin),
        Node(; id="B", node_type=:other),
        Node(; id="D", node_type=:destination),
    ]
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
    sol = TPO.solve(instance; local_search=false, show_progress=false)

    @test all(!isempty, sol.bundle_paths)
    @test TPO.is_feasible(sol, instance; verbose=true)
    @test TPO.cost(sol) ≈ TPO.cost(TPO.Solution(sol.bundle_paths, instance))

    result = TPO.solve_filtered(instance; show_progress=false)
    chained = TPO.merge_solutions(
        result.filtering_solution, result.solution, instance, result.sub_instance
    )
    @test sol.bundle_paths == chained.bundle_paths
    @test TPO.cost(sol) ≈ TPO.cost(chained)
end

@testset "solve with local search equals the hand-chained pipeline" begin
    instance = TestFixtures.small_instance()
    sol = TPO.solve(instance; LS..., rng=MersenneTwister(0), show_progress=false)
    @test TPO.is_feasible(sol, instance; verbose=true)

    result = TPO.solve_filtered(instance; show_progress=false)
    TPO.local_search!(result.solution, result.sub_instance; LS..., rng=MersenneTwister(0))
    chained = TPO.merge_solutions(
        result.filtering_solution, result.solution, instance, result.sub_instance
    )
    @test sol.bundle_paths == chained.bundle_paths
    @test TPO.cost(sol) ≈ TPO.cost(chained)
end

@testset "solve on a non-wrapping instance is feasible" begin
    instance = TestFixtures.small_instance(; wrap_time=false)
    sol = TPO.solve(instance; time_limit=5.0, max_iter=50, show_progress=false)
    @test TPO.is_feasible(sol, instance; verbose=true)
end

@testset "solve keeps the filtering path of a filtered bundle (departure mode)" begin
    instance = TestFixtures.shared_arc_instance()
    filtering_solution = TPO.lower_bound_filtering(instance; show_progress=false)
    sol = TPO.solve(instance; time_limit=1.0, max_iter=50, show_progress=false)

    @test TPO.is_feasible(sol, instance; verbose=true)
    filtered = findfirst(p -> length(p) <= 2, filtering_solution.bundle_paths)
    @test !isnothing(filtered)
    @test sol.bundle_paths[filtered] == filtering_solution.bundle_paths[filtered]
end

@testset "solve when every bundle is filtered out" begin
    nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]
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

    sol = @test_logs (:info, r"sub-instance is empty") match_mode = :any TPO.solve(
        instance; show_progress=false
    )
    @test sol.bundle_paths == filtering_solution.bundle_paths
    @test TPO.is_feasible(sol, instance; verbose=true)
end

@testset "solve on a multi-modal instance keeps a bundle and is feasible" begin
    instance = multimodal_instance()
    sub_instance = TPO.solve_filtered(instance; show_progress=false).sub_instance
    @test bundle_count(sub_instance) > 0

    sol = TPO.solve(instance; time_limit=2.0, max_iter=100, show_progress=false)
    @test TPO.is_feasible(sol, instance; verbose=true)
end

@testset "solve with filtering=false equals construction plus local search" begin
    instance = TestFixtures.small_instance()
    sol = TPO.solve(
        instance; filtering=false, LS..., rng=MersenneTwister(0), show_progress=false
    )
    @test TPO.is_feasible(sol, instance; verbose=true)

    chained = TPO.mix_greedy_heuristic(instance; show_progress=false)
    TPO.local_search!(chained, instance; LS..., rng=MersenneTwister(0))
    @test TPO.cost(sol) ≈ TPO.cost(chained)
    @test sol.bundle_paths == chained.bundle_paths
end
