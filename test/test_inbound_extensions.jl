using Test
using TransportationPlanningOptimization

isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound

const TPO = TransportationPlanningOptimization

@testset "CarbonArcCost is linear in volume" begin
    C = TPO.LightCommodity{true,Nothing}
    items = [
        LightCommodity(;
            origin_id="o",
            destination_id="d",
            size=Float64(s),
            info=nothing,
            is_date_arrival=true,
        ) for s in (1.0, 2.0, 3.0)
    ]
    c = CarbonArcCost(0.5)
    @test isapprox(TPO.evaluate(c, items), 0.5 * 6.0; atol=1e-9)
    @test isapprox(TPO.incremental_cost(c, C[], items), 0.5 * 6.0; atol=1e-9)
    @test isapprox(TPO.lower_bound_incremental_cost(c, C[], items), 0.5 * 6.0; atol=1e-9)
end

@testset "StockArcCost reads info.stock_cost and scales by distance" begin
    items = [
        LightCommodity(;
            origin_id="o",
            destination_id="d",
            size=1.0,
            info=InboundCommodityInfo(2.5),
            is_date_arrival=true,
        ),
        LightCommodity(;
            origin_id="o",
            destination_id="d",
            size=1.0,
            info=InboundCommodityInfo(1.5),
            is_date_arrival=true,
        ),
    ]
    c = StockArcCost(10.0)
    # 10.0 * (2.5 + 1.5) = 40.0
    @test isapprox(TPO.evaluate(c, items), 40.0; atol=1e-9)
end

@testset "NodeVolumeCost is linear in volume" begin
    items = [
        LightCommodity(;
            origin_id="o",
            destination_id="d",
            size=Float64(s),
            info=nothing,
            is_date_arrival=true,
        ) for s in (10.0, 20.0)
    ]
    c = NodeVolumeCost(3.0)
    # 3.0 * 30 = 90
    @test isapprox(TPO.evaluate(c, items), 90.0; atol=1e-9)
end

@testset "parse_inbound_instance attaches carbon, stock, node costs" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )

    # Every node should have a NodeVolumeCost.
    @test all(n -> n.node_cost isa NodeVolumeCost, nodes)

    # At least one arc's cost should be a SumArcCost containing CarbonArcCost
    # and StockArcCost.
    sum_arcs = filter(a -> a.cost isa SumArcCost, arcs)
    @test !isempty(sum_arcs)
    if !isempty(sum_arcs)
        terms = sum_arcs[1].cost.terms
        types = typeof.(terms)
        @test any(t -> t <: CarbonArcCost, types)
        @test any(t -> t <: StockArcCost, types)
    end

    # Every commodity should carry InboundCommodityInfo.
    @test all(c -> c.info isa InboundCommodityInfo, commodities)
end
