using Test
using TransportationPlanningOptimization
using Dates

const TPO = TransportationPlanningOptimization

isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound

@testset "slope_scaling_update! populates cost_scaling" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)

    @test isempty(instance.travel_time_graph.cost_scaling)
    slope_scaling_update!(instance, sol)
    @test !isempty(instance.travel_time_graph.cost_scaling)
end

@testset "slope_scaling_update! factors are between 0 and 2" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    slope_scaling_update!(instance, sol)

    for factor in values(instance.travel_time_graph.cost_scaling)
        @test 0.0 < factor <= 2.0
    end
end

@testset "slope_scaling_update! on empty solution leaves cost_scaling empty" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = Solution(instance)
    slope_scaling_update!(instance, sol)
    @test isempty(instance.travel_time_graph.cost_scaling)
end

@testset "slope_scaling_update! excludes factors of exactly 1.0" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    slope_scaling_update!(instance, sol)

    for factor in values(instance.travel_time_graph.cost_scaling)
        @test !isapprox(factor, 1.0; atol=1e-9)
    end
end

@testset "slope_scaling_update! clears stale entries between calls" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    slope_scaling_update!(instance, sol)
    @test !isempty(instance.travel_time_graph.cost_scaling)

    empty_sol = Solution(instance)
    slope_scaling_update!(instance, empty_sol)
    @test isempty(instance.travel_time_graph.cost_scaling)
end
