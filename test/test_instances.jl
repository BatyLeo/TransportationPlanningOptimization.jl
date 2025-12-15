"""
Tests for Instance creation and integration using Inbound test application
"""

using NetworkDesignOptimization
using Test

include("Inbound.jl")
using .Inbound

@testset "Instance creation" begin
    @test begin
        nodes = [
            NetworkNode(; id="1", cost=10.0, capacity=100, info=nothing),
            NetworkNode(; id="2", cost=20.0, capacity=200, info=nothing),
        ]
        arcs = [
            NetworkArc(;
                origin_id="1", destination_id="2", cost=LinearArcCost(5.0), info=nothing
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=10.0,
                quantity=5,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        instance = build_instance(nodes, arcs, commodities, Week(1))
        length(instance.bundles) > 0
    end
end

@testset "Instance with Inbound test data" begin
    inbound_data_dir = joinpath(@__DIR__, "public")
    nodes_file = joinpath(inbound_data_dir, "small_nodes.csv")
    legs_file = joinpath(inbound_data_dir, "small_legs.csv")
    routes_file = joinpath(inbound_data_dir, "small_routes.csv")
    commodities_file = joinpath(inbound_data_dir, "small_commodities.csv")

    @test isfile(nodes_file) && isfile(legs_file) && isfile(routes_file) && isfile(commodities_file)
    (; nodes, arcs, commodities) = read_inbound_instance(nodes_file, legs_file, commodities_file)
    instance = build_instance(nodes, arcs, commodities, Week(1))
    nb_bundles = length(instance.bundles)
    nb_orders = sum(length(bundle.orders) for bundle in instance.bundles)
    nb_commodities = sum(
        length(order.commodities) for bundle in instance.bundles for order in bundle.orders
    )
    @test nb_bundles == 312
    @test nb_orders == 1983
    @test nb_commodities == 45323
end

@testset "Instance bundle aggregation" begin
    @test begin
        nodes = [
            NetworkNode(; id="A", cost=5.0, capacity=50, info=nothing),
            NetworkNode(; id="B", cost=10.0, capacity=100, info=nothing),
            NetworkNode(; id="C", cost=15.0, capacity=150, info=nothing),
        ]
        arcs = [
            NetworkArc(;
                origin_id="A", destination_id="B", cost=LinearArcCost(2.0), info=nothing
            ),
            NetworkArc(;
                origin_id="B", destination_id="C", cost=LinearArcCost(3.0), info=nothing
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="B",
                size=5.0,
                quantity=2,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
            Commodity(;
                origin_id="A",
                destination_id="B",
                size=7.0,
                quantity=3,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
            Commodity(;
                origin_id="B",
                destination_id="C",
                size=10.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 2),
                max_delivery_time=Week(2),
            ),
        ]
        instance = build_instance(nodes, arcs, commodities, Week(1))
        # Should create 2 bundles: A->B and B->C
        length(instance.bundles) == 2
    end
end

@testset "Instance with linear arc costs" begin
    @test begin
        nodes = [
            NetworkNode(; id="1", cost=0.0, capacity=1000, info=nothing),
            NetworkNode(; id="2", cost=0.0, capacity=1000, info=nothing),
        ]
        arcs = [
            NetworkArc(;
                origin_id="1", destination_id="2", cost=LinearArcCost(1.5), info=nothing
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=20.0,
                quantity=5,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        instance = build_instance(nodes, arcs, commodities, Week(1))
        instance.bundles[1].origin_id == "1" && instance.bundles[1].destination_id == "2"
    end
end

@testset "Instance with bin packing arc costs" begin
    @test begin
        nodes = [
            NetworkNode(; id="1", cost=0.0, capacity=500, info=nothing),
            NetworkNode(; id="2", cost=0.0, capacity=500, info=nothing),
        ]
        arcs = [
            NetworkArc(;
                origin_id="1",
                destination_id="2",
                cost=BinPackingArcCost(100.0, 50.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=15.0,
                quantity=3,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        instance = build_instance(nodes, arcs, commodities, Week(1))
        length(instance.bundles) == 1
    end
end

@testset "Instance with heterogeneous arc costs" begin
    @test begin
        nodes = [
            NetworkNode(; id="1", cost=0.0, capacity=1000, info=nothing),
            NetworkNode(; id="2", cost=0.0, capacity=1000, info=nothing),
            NetworkNode(; id="3", cost=0.0, capacity=1000, info=nothing),
        ]
        arcs = [
            NetworkArc(;
                origin_id="1", destination_id="2", cost=LinearArcCost(2.0), info=nothing
            ),
            NetworkArc(;
                origin_id="2",
                destination_id="3",
                cost=BinPackingArcCost(50.0, 40.0),
                info=nothing,
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=10.0,
                quantity=2,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
            Commodity(;
                origin_id="2",
                destination_id="3",
                size=25.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(1),
            ),
        ]
        instance = build_instance(nodes, arcs, commodities, Week(1))
        length(instance.bundles) == 2
    end
end

@testset "Instance time period handling" begin
    @test begin
        nodes = [
            NetworkNode(; id="1", cost=0.0, capacity=100, info=nothing),
            NetworkNode(; id="2", cost=0.0, capacity=100, info=nothing),
        ]
        arcs = [
            NetworkArc(;
                origin_id="1", destination_id="2", cost=LinearArcCost(1.0), info=nothing
            ),
        ]
        commodities = [
            Commodity(;
                origin_id="1",
                destination_id="2",
                size=5.0,
                quantity=1,
                arrival_date=DateTime(2024, 1, 1),
                max_delivery_time=Week(2),
            ),
        ]
        # Test with different time periods
        instance_week = build_instance(nodes, arcs, commodities, Week(1))
        instance_day = build_instance(nodes, arcs, commodities, Day(1))
        length(instance_week.bundles) == 1 && length(instance_day.bundles) == 1
    end
end
