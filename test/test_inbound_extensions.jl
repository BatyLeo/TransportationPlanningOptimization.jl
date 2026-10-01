using Test
using TransportationPlanningOptimization

using TransportationPlanningOptimization.Problems.Inbound

const TPO = TransportationPlanningOptimization

@testset "StockArcCost reads info.stock_cost and scales by distance" begin
    items = [
        LightCommodity(;
            origin_id="o", destination_id="d", size=1.0, info=InboundCommodityInfo(2.5)
        ),
        LightCommodity(;
            origin_id="o", destination_id="d", size=1.0, info=InboundCommodityInfo(1.5)
        ),
    ]
    c = StockArcCost(10.0)
    # 10.0 * (2.5 + 1.5) = 40.0
    @test isapprox(TPO.evaluate(c, items), 40.0; atol=1e-9)
end

@testset "StockArcCost incremental costs are additive" begin
    mk(x) = LightCommodity(;
        origin_id="o", destination_id="d", size=1.0, info=InboundCommodityInfo(x)
    )
    existing = [mk(2.5), mk(1.5)]
    new = [mk(3.0), mk(0.5)]
    c = StockArcCost(10.0)
    s = TPO.SumArcCost((c, LinearArcCost(1.0)))
    for ex in (empty(new), existing), f in (c, s)
        expected = TPO.evaluate(f, vcat(ex, new)) - TPO.evaluate(f, ex)
        @test TPO.incremental_cost(f, ex, new) ≈ expected
        @test TPO.lower_bound_incremental_cost(f, ex, new) ≈ expected
    end
    for f in (c, s)
        TPO.lower_bound_incremental_cost(f, existing, new)
        @test @allocated(TPO.lower_bound_incremental_cost(f, existing, new)) == 0
    end
end

@testset "LinearNodeCost is linear in volume" begin
    items = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (10.0, 20.0)
    ]
    c = LinearNodeCost(3.0)
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

    # Every node should have a LinearNodeCost.
    @test all(n -> n.node_cost isa LinearNodeCost, nodes)

    # At least one arc's cost should be a SumArcCost containing LinearArcCost
    # (carbon cost) and StockArcCost.
    sum_arcs = filter(a -> a.cost isa SumArcCost, arcs)
    @test !isempty(sum_arcs)
    if !isempty(sum_arcs)
        terms = sum_arcs[1].cost.terms
        types = typeof.(terms)
        @test any(t -> t <: LinearArcCost, types)
        @test any(t -> t <: StockArcCost, types)
    end

    # Every commodity should carry InboundCommodityInfo.
    @test all(c -> c.info isa InboundCommodityInfo, commodities)
end
