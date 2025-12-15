"""
Tests for Bundle data structures
"""

using NetworkDesignOptimization
using Test

@testset "Bundle creation" begin
    @test begin
        light_commodity = LightCommodity(; origin_id="1", destination_id="2", size=10.0)
        order = Order(;
            commodities=[light_commodity], delivery_time_step=1, max_delivery_time_step=7
        )
        bundle = Bundle(; orders=[order], origin_id="1", destination_id="2")
        bundle.origin_id == "1" &&
            bundle.destination_id == "2" &&
            length(bundle.orders) == 1
    end
end

@testset "Bundle with multiple orders" begin
    @test begin
        orders = [
            Order(;
                commodities=[
                    LightCommodity(; origin_id="1", destination_id="2", size=10.0)
                ],
                delivery_time_step=1,
                max_delivery_time_step=7,
            ),
            Order(;
                commodities=[
                    LightCommodity(; origin_id="1", destination_id="2", size=15.0)
                ],
                delivery_time_step=2,
                max_delivery_time_step=14,
            ),
            Order(;
                commodities=[LightCommodity(; origin_id="1", destination_id="2", size=5.0)],
                delivery_time_step=3,
                max_delivery_time_step=21,
            ),
        ]
        bundle = Bundle(; orders=orders, origin_id="A", destination_id="B")
        length(bundle.orders) == 3
    end
end

@testset "Bundle route consistency" begin
    # All orders in a bundle should have same origin-destination
    @test begin
        orders = [
            Order(;
                commodities=[
                    LightCommodity(; origin_id="X", destination_id="Y", size=10.0)
                ],
                delivery_time_step=1,
                max_delivery_time_step=7,
            ),
            Order(;
                commodities=[
                    LightCommodity(; origin_id="X", destination_id="Y", size=20.0)
                ],
                delivery_time_step=2,
                max_delivery_time_step=14,
            ),
        ]
        bundle = Bundle(; orders=orders, origin_id="X", destination_id="Y")
        bundle.origin_id == "X" && bundle.destination_id == "Y"
    end
end

@testset "Bundle with empty orders" begin
    @test begin
        bundle = Bundle(; orders=Order[], origin_id="1", destination_id="2")
        length(bundle.orders) == 0 &&
            bundle.origin_id == "1" &&
            bundle.destination_id == "2"
    end
end

@testset "Bundle aggregation metrics" begin
    @test begin
        orders = [
            Order(;
                commodities=[
                    LightCommodity(; origin_id="1", destination_id="2", size=5.0),
                    LightCommodity(; origin_id="1", destination_id="2", size=5.0),
                ],
                delivery_time_step=1,
                max_delivery_time_step=7,
            ),
            Order(;
                commodities=[
                    LightCommodity(; origin_id="1", destination_id="2", size=10.0)
                ],
                delivery_time_step=2,
                max_delivery_time_step=14,
            ),
        ]
        bundle = Bundle(; orders=orders, origin_id="1", destination_id="2")
        total_commodities = sum(length(o.commodities) for o in bundle.orders)
        total_size = sum(sum(c.size for c in o.commodities) for o in bundle.orders)
        total_commodities == 3 && isapprox(total_size, 20.0)
    end
end

@testset "Bundle with different origin-destination pairs" begin
    # Test that different routes create separate bundles
    @test begin
        bundle1 = Bundle(;
            orders=[
                Order(;
                    commodities=[
                        LightCommodity(; origin_id="A", destination_id="B", size=10.0)
                    ],
                    delivery_time_step=1,
                    max_delivery_time_step=7,
                ),
            ],
            origin_id="A",
            destination_id="B",
        )
        bundle2 = Bundle(;
            orders=[
                Order(;
                    commodities=[
                        LightCommodity(; origin_id="C", destination_id="D", size=15.0)
                    ],
                    delivery_time_step=1,
                    max_delivery_time_step=7,
                ),
            ],
            origin_id="C",
            destination_id="D",
        )
        bundle1.origin_id != bundle2.origin_id &&
            bundle1.destination_id != bundle2.destination_id
    end
end
