using Test
using Dates
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "solve_filtered returns feasible solution on the sub-instance" begin
    instance = TestFixtures.small_instance()

    result = TPO.solve_filtered(instance)

    @test result isa NamedTuple
    @test haskey(result, :solution)
    @test haskey(result, :sub_instance)
    @test TPO.is_feasible(result.solution, result.sub_instance)
    @test isfinite(TPO.cost(result.solution))
end

@testset "solve_filtered solution is at most greedy on the sub-instance" begin
    instance = TestFixtures.small_instance()

    result = TPO.solve_filtered(instance)
    greedy_baseline = TPO.greedy_heuristic(result.sub_instance)

    @test TPO.cost(result.solution) <= TPO.cost(greedy_baseline)
end
