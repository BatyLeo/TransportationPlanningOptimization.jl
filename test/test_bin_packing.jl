using Test
using Dates
using TransportationPlanningOptimization

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "Oversized commodity detection" begin
    arc = NetworkArc(;
        travel_time_steps=1, capacity=typemax(Int), cost=BinPackingArcCost(10.0, 65)
    )
    big = LightCommodity(; origin_id="a", destination_id="b", size=66.0)
    @test_throws DomainError TransportationPlanningOptimization.compute_bin_assignments(
        arc.cost, [big]
    )
end

@testset "Greedy fails on input with oversized items" begin
    nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=BinPackingArcCost(10.0, 65),
            travel_time=Day(1),
        ),
    ]
    base_date = DateTime(2025, 11, 20)
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            arrival_date=base_date + Day(1),
            size=124.02,
            max_delivery_time=Day(1),
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    @test_throws DomainError greedy_heuristic(instance; show_progress=false)
end
