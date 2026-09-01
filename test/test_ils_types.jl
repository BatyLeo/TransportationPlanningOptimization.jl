using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound

@testset "ILSConfig defaults" begin
    config = ILSConfig()
    @test config.time_limit == 1800.0
    @test config.perturbation_time_limit == 180.0
    @test config.ls_time_limit == 300.0
    @test config.change_threshold_ratio == 0.15
    @test config.cost_threshold_ratio == 0.0175
    @test config.max_no_change == 3
    @test config.max_no_improv == 3
end

@testset "ILSConfig custom values" begin
    config = ILSConfig(; time_limit=600, ls_time_limit=60)
    @test config.time_limit == 600.0
    @test config.ls_time_limit == 60.0
    @test config.max_no_change == 3  # default kept
end

@testset "ILSResult construction" begin
    result = ILSResult(100.0, 500.0, 5, 120.0, [(0.0, 600.0), (30.0, 550.0), (90.0, 500.0)])
    @test result.improvement == 100.0
    @test result.best_cost == 500.0
    @test result.iterations == 5
    @test result.time_elapsed == 120.0
    @test length(result.cost_history) == 3
end

@testset "AbstractPerturbation fallback errors" begin
    struct DummyPerturbation <: AbstractPerturbation end
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = Solution(instance)
    @test_throws ErrorException perturbate!(sol, instance, DummyPerturbation())
end
