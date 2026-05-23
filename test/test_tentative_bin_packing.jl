using Test
using Random
using TransportationPlanningOptimization

@testset "tentative_bin_count matches compute_bin_assignments" begin
    arc_f = BinPackingArcCost(10.0, 100)
    C = LightCommodity{true,Nothing}
    items = C[]
    for s in [40, 60, 35, 25, 80, 15, 50]
        push!(
            items,
            LightCommodity(;
                origin_id="o",
                destination_id="d",
                size=Float64(s),
                info=nothing,
                is_date_arrival=true,
            ),
        )
    end
    materialized = TransportationPlanningOptimization.compute_bin_assignments(arc_f, items)
    @test tentative_bin_count(arc_f, items) == length(materialized)
end

@testset "tentative_bin_count on empty input" begin
    arc_f = BinPackingArcCost(10.0, 100)
    C = LightCommodity{true,Nothing}
    @test tentative_bin_count(arc_f, C[]) == 0
end

@testset "tentative_bin_count: single item fits exactly" begin
    arc_f = BinPackingArcCost(10.0, 100)
    C = LightCommodity{true,Nothing}
    item = LightCommodity(;
        origin_id="o", destination_id="d", size=100.0, info=nothing, is_date_arrival=true
    )
    @test tentative_bin_count(arc_f, [item]) == 1
end

@testset "tentative_bin_count: oversized item throws DomainError" begin
    arc_f = BinPackingArcCost(10.0, 100)
    big = LightCommodity(;
        origin_id="o", destination_id="d", size=150.0, info=nothing, is_date_arrival=true
    )
    @test_throws DomainError tentative_bin_count(arc_f, [big])
end

@testset "tentative_bin_count: all items fit in one bin" begin
    arc_f = BinPackingArcCost(10.0, 100)
    sizes = [10.0, 20.0, 30.0, 25.0]
    items = [
        LightCommodity(;
            origin_id="o", destination_id="d", size=s, info=nothing, is_date_arrival=true
        ) for s in sizes
    ]
    @test tentative_bin_count(arc_f, items) == 1
end

@testset "tentative_bin_count: randomized parity with compute_bin_assignments" begin
    rng = MersenneTwister(20260521)
    arc_f = BinPackingArcCost(10.0, 100)
    for trial in 1:30
        n = rand(rng, 5:40)
        items = [
            LightCommodity(;
                origin_id="o",
                destination_id="d",
                size=Float64(rand(rng, 1:100)),
                info=nothing,
                is_date_arrival=true,
            ) for _ in 1:n
        ]
        @test tentative_bin_count(arc_f, items) == length(
            TransportationPlanningOptimization.compute_bin_assignments(arc_f, items)
        )
    end
end
