using Test
using Dates
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound: parse_inbound_instance

@testset "solve_filtered returns feasible solution on the sub-instance" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    result = TPO.solve_filtered(instance)

    @test result isa NamedTuple
    @test haskey(result, :solution)
    @test haskey(result, :sub_instance)
    @test TPO.is_feasible(result.solution, result.sub_instance)
    @test isfinite(TPO.cost(result.solution))
end

@testset "solve_filtered solution is at most greedy on the sub-instance" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    result = TPO.solve_filtered(instance)
    greedy_baseline = TPO.greedy_heuristic(result.sub_instance)

    @test TPO.cost(result.solution) <= TPO.cost(greedy_baseline)
end
