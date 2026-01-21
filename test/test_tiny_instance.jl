"""
Tests for the tiny inbound logistics instance.
"""

using TransportationPlanningOptimization
using Graphs
using Test

@testset "Tiny Inbound Instance" begin
    instance_name = "tiny"
    datadir = joinpath(@__DIR__, "public")
    nodes_file = joinpath(datadir, "$(instance_name)_nodes.csv")
    legs_file = joinpath(datadir, "$(instance_name)_legs.csv")
    commodities_file = joinpath(datadir, "$(instance_name)_commodities.csv")

    (; nodes, arcs, commodities) = parse_inbound_instance(
        nodes_file, legs_file, commodities_file
    )

    wrapped_instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    unwrapped_instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=false)

    @test bundle_count(wrapped_instance) == 4
    @test order_count(wrapped_instance) == 6
    @test commodity_count(wrapped_instance) == 21
    @test wrapped_instance.time_horizon_length == 6
    @test nv(wrapped_instance.network_graph.graph) == 8
    @test nv(unwrapped_instance.network_graph.graph) == 8
    @test nv(wrapped_instance.time_space_graph.graph) == 48
    @test ne(wrapped_instance.time_space_graph.graph) == 84
    @test nv(wrapped_instance.travel_time_graph.graph) == 44
    @test ne(wrapped_instance.travel_time_graph.graph) == 58

    @test bundle_count(unwrapped_instance) == 4
    @test order_count(unwrapped_instance) == 6
    @test commodity_count(unwrapped_instance) == 21
    @test unwrapped_instance.time_horizon_length == 11
    @test ne(wrapped_instance.network_graph.graph) == 14
    @test ne(unwrapped_instance.network_graph.graph) == 14
    @test nv(unwrapped_instance.time_space_graph.graph) == 88
    @test ne(unwrapped_instance.time_space_graph.graph) == 124
    @test nv(unwrapped_instance.travel_time_graph.graph) == 44
    @test ne(unwrapped_instance.travel_time_graph.graph) == 58
end
