using Test
using Dates
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "solve_filtered returns feasible solution on the sub-instance" begin
    instance = TestFixtures.small_instance()

    result = TPO.solve_filtered(instance; show_progress=false)

    @test result isa NamedTuple
    @test haskey(result, :solution_state)
    @test haskey(result, :sub_instance)
    @test haskey(result, :filtering_state)
    @test TPO.is_feasible(result.solution_state, result.sub_instance)
    @test isfinite(TPO.cost(result.solution_state))
end

@testset "solve_filtered -> local_search! -> merge_solutions is feasible when a filtered bundle shares an arc with a kept bundle" begin
    instance = TestFixtures.shared_arc_instance()

    result = TPO.solve_filtered(instance; show_progress=false)
    TPO.local_search!(result.solution_state, result.sub_instance; time_limit=1.0)
    @test TPO.is_feasible(result.solution_state, result.sub_instance; verbose=true)
    merged = TPO.merge_solutions(
        result.filtering_state, result.solution_state, instance, result.sub_instance
    )
    @test TPO.is_feasible(merged, instance; verbose=true)
end
