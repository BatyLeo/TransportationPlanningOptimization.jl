"""
Tests for Order data structures and consolidation logic
"""

using Dates
using NetworkDesignOptimization
using Test

@testset "Order creation" begin
    light_commodity = LightCommodity(; origin_id="1", destination_id="2", size=10.0)
    order = Order(; commodities=[light_commodity], time_step=1, max_transit_steps=7)
    @test length(order.commodities) == 1
    @test order.time_step == 1
    @test order.max_transit_steps == 7
end

@testset "Order with multiple commodities" begin
    @test begin
        light_commodities = [
            LightCommodity(; origin_id="1", destination_id="2", size=10.0),
            LightCommodity(; origin_id="1", destination_id="2", size=15.0),
            LightCommodity(; origin_id="1", destination_id="2", size=5.0),
        ]
        order = Order(; commodities=light_commodities, time_step=2, max_transit_steps=14)
        length(order.commodities) == 3 && sum(c.size for c in order.commodities) == 30.0
    end
end

@testset "Error handling in Order constructor" begin
    @test_throws DomainError Order(;
        commodities=[LightCommodity(; origin_id="1", destination_id="2", size=10.0)],
        time_step=0,
        max_transit_steps=7,
    )

    @test_throws DomainError Order(;
        commodities=[LightCommodity(; origin_id="1", destination_id="2", size=10.0)],
        time_step=1,
        max_transit_steps=-5,
    )
end

@testset "Order with custom commodity info" begin
    @test begin
        struct TestCommodityInfo
            id::Int
        end
        light_commodities = [
            LightCommodity(;
                origin_id="1", destination_id="2", size=10.0, info=TestCommodityInfo(1)
            ),
            LightCommodity(;
                origin_id="1", destination_id="2", size=15.0, info=TestCommodityInfo(2)
            ),
        ]
        order = Order(; commodities=light_commodities, time_step=3, max_transit_steps=21)
        order.commodities[1].info.id == 1 && order.commodities[2].info.id == 2
    end
end

@testset "Order aggregation of commodity sizes" begin
    @test begin
        light_commodities = [
            LightCommodity(; origin_id="1", destination_id="2", size=1.5),
            LightCommodity(; origin_id="1", destination_id="2", size=2.5),
            LightCommodity(; origin_id="1", destination_id="2", size=3.0),
        ]
        order = Order(; commodities=light_commodities, time_step=1, max_transit_steps=7)
        total_size = sum(c.size for c in order.commodities)
        isapprox(total_size, 7.0)
    end
end
