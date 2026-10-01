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

function _alloc_inbound_order_lb(f, order)
    TPO.lower_bound_incremental_cost_with_order(f, nothing, order)
    return @allocated TPO.lower_bound_incremental_cost_with_order(f, nothing, order)
end

@testset "Order aggregates the inbound stock cost for O(1) lower bounds" begin
    mk(s, x) = LightCommodity(;
        origin_id="o", destination_id="d", size=s, info=InboundCommodityInfo(x)
    )
    order = Order(;
        commodities=[mk(0.3, 0.1), mk(1.7, 2.3), mk(0.9, 0.7)],
        time_step=1,
        max_transit_steps=1,
    )
    @test order.aggregate.stock_cost ===
        sum(x.info.stock_cost for x in order.commodities; init=0.0)
    f = TPO.SumArcCost((StockArcCost(3.7), LinearArcCost(1.3), BinPackingArcCost(2.9, 5)))
    C = eltype(order.commodities)
    @test TPO.lower_bound_incremental_cost_with_order(f, nothing, order) ===
        TPO.lower_bound_incremental_cost(f, C[], order.commodities)
    @test _alloc_inbound_order_lb(f, order) == 0
end
