"""
Tests for Commodity and LightCommodity data structures
"""

using Dates
using TransportationPlanningOptimization
using Test

@testset "Commodity and LightCommodity creation" begin
    @test begin
        commodity = Commodity(;
            origin_id="1",
            destination_id="2",
            size=10.0,
            quantity=5,
            arrival_date=DateTime(2024, 1, 1),
            max_delivery_time=Week(1),
        )
        commodity.origin_id == "1" &&
            commodity.destination_id == "2" &&
            commodity.size == 10.0 &&
            commodity.quantity == 5
    end

    @test begin
        light_commodity = LightCommodity(; origin_id="10", destination_id="20", size=25.0)
        light_commodity.origin_id == "10" &&
            light_commodity.destination_id == "20" &&
            light_commodity.size == 25.0
    end

    @test begin
        struct CustomInfo
            data::String
        end
        commodity = Commodity(;
            origin_id="A",
            destination_id="B",
            size=5.5,
            quantity=10,
            arrival_date=DateTime(2024, 1, 15),
            max_delivery_time=Week(2),
            info=CustomInfo("test"),
        )
        commodity.info.data == "test" && commodity.size == 5.5
    end
end

@testset "Error handling in constructors" begin
    # Test that commodities with size 0 throw an error
    @test_throws DomainError Commodity(;
        origin_id="1",
        destination_id="2",
        size=0.0,
        quantity=0,
        arrival_date=DateTime(2024, 1, 1),
        max_delivery_time=Week(1),
    )

    @test_throws DomainError LightCommodity(; origin_id="10", destination_id="20", size=0.0)
end

@testset "Commodity with different date formats" begin
    # Test various DateTime instantiations
    c1 = Commodity(;
        origin_id="1",
        destination_id="2",
        size=10.0,
        quantity=5,
        arrival_date=DateTime(2024, 1, 1, 0, 0, 0),
        max_delivery_time=Week(1),
    )
    c2 = Commodity(;
        origin_id="1",
        destination_id="2",
        size=10.0,
        quantity=5,
        departure_date=DateTime(2024, 6, 15, 12, 30, 45),
        max_delivery_time=Week(1),
    )

    @test month(c1.date) == 1 && month(c2.date) == 6
    @test typeof(c1) <: Commodity{true}
    @test typeof(c2) <: Commodity{false}
end
