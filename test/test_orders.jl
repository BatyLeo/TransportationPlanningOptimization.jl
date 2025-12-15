"""
Tests for Order data structures and consolidation logic
"""

using Dates
using NetworkDesignOptimization
using Test

@testset "Order creation" begin
    light_commodity = LightCommodity(; origin_id="1", destination_id="2", size=10.0)
    order = Order(;
        commodities=[light_commodity], delivery_time_step=1, max_delivery_time_step=7
    )
    @test length(order.commodities) == 1
    @test order.delivery_time_step == 1
    @test order.max_delivery_time_step == 7
end

@testset "Order with multiple commodities" begin
    @test begin
        light_commodities = [
            LightCommodity(; origin_id="1", destination_id="2", size=10.0),
            LightCommodity(; origin_id="1", destination_id="2", size=15.0),
            LightCommodity(; origin_id="1", destination_id="2", size=5.0),
        ]
        order = Order(;
            commodities=light_commodities, delivery_time_step=2, max_delivery_time_step=14
        )
        length(order.commodities) == 3 && sum(c.size for c in order.commodities) == 30.0
    end
end

@testset "Error handling in Order constructor" begin
    @test_throws DomainError Order(;
        commodities=[LightCommodity(; origin_id="1", destination_id="2", size=10.0)],
        delivery_time_step=0,
        max_delivery_time_step=7,
    )

    @test_throws DomainError Order(;
        commodities=[LightCommodity(; origin_id="1", destination_id="2", size=10.0)],
        delivery_time_step=1,
        max_delivery_time_step=-5,
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
        order = Order(;
            commodities=light_commodities, delivery_time_step=3, max_delivery_time_step=21
        )
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
        order = Order(;
            commodities=light_commodities, delivery_time_step=1, max_delivery_time_step=7
        )
        total_size = sum(c.size for c in order.commodities)
        isapprox(total_size, 7.0)
    end
end
