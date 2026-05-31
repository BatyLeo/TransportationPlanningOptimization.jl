using Test
using TransportationPlanningOptimization
using Dates
const TPO = TransportationPlanningOptimization

# Build a small bag of LightCommodity{false,Nothing} values for testing.
function _mk(size::Float64, sup::String="S", cust::String="C")
    return TPO.LightCommodity(; origin_id=sup, destination_id=cust, size=size, info=nothing)
end

@testset "_drain_first_matches! contract" begin
    @testset "no removal when to_remove is empty" begin
        pool = [_mk(1.0), _mk(2.0)]
        to_remove = TPO.LightCommodity{false,Nothing}[]
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test isempty(dropped)
        @test pool == [_mk(1.0), _mk(2.0)]
        @test isempty(to_remove)
    end

    @testset "single match (small to_remove, common case)" begin
        pool = [_mk(1.0), _mk(2.0), _mk(3.0)]
        to_remove = [_mk(2.0)]
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test dropped == [_mk(2.0)]
        @test pool == [_mk(1.0), _mk(3.0)]
        @test isempty(to_remove)
    end

    @testset "multi-set semantics: removes N when N duplicates in to_remove" begin
        pool = [_mk(1.0), _mk(1.0), _mk(1.0), _mk(2.0)]
        to_remove = [_mk(1.0), _mk(1.0)]  # remove 2 of the 1.0's
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test length(dropped) == 2
        @test all(d -> d == _mk(1.0), dropped)
        @test pool == [_mk(1.0), _mk(2.0)]
        @test isempty(to_remove)
    end

    @testset "unmatched items remain in to_remove in original order" begin
        pool = [_mk(1.0), _mk(2.0)]
        # 3.0 and 4.0 don't exist in pool, 2.0 does
        to_remove = [_mk(3.0), _mk(2.0), _mk(4.0)]
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test dropped == [_mk(2.0)]
        @test pool == [_mk(1.0)]
        # Unmatched are 3.0 and 4.0, in their original order
        @test to_remove == [_mk(3.0), _mk(4.0)]
    end

    @testset "partial multi-set match: 3 wanted, 2 in pool" begin
        pool = [_mk(1.0), _mk(1.0), _mk(2.0)]
        to_remove = [_mk(1.0), _mk(1.0), _mk(1.0)]  # want 3, only 2 in pool
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test length(dropped) == 2
        @test pool == [_mk(2.0)]
        # One 1.0 should remain unmatched
        @test to_remove == [_mk(1.0)]
    end

    @testset "large to_remove (forces Dict path)" begin
        # 50 commodities, half match the pool's 50 items, half don't.
        pool = [_mk(Float64(i)) for i in 1:50]
        to_remove = vcat(
            [_mk(Float64(i)) for i in 1:25],          # match
            [_mk(Float64(i + 1000)) for i in 1:25],   # don't match
        )
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test length(dropped) == 25
        @test length(pool) == 25
        @test all(p -> p.size > 25, pool)  # only items 26..50 remain
        @test length(to_remove) == 25
        @test all(r -> r.size > 1000, to_remove)
    end

    @testset "very large to_remove (>32, forces Dict)" begin
        # 100 to_remove, all matching. Stress the multi-set count handling.
        pool = vcat([_mk(Float64(i)) for i in 1:100], [_mk(999.0)])
        to_remove = [_mk(Float64(i)) for i in 1:100]
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test length(dropped) == 100
        @test pool == [_mk(999.0)]
        @test isempty(to_remove)
    end

    @testset "tail just above linear threshold (boundary)" begin
        # length(to_remove) == 9 — should force Dict path.
        pool = [_mk(Float64(i)) for i in 1:9]
        to_remove = [_mk(Float64(i)) for i in 1:9]
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test length(dropped) == 9
        @test isempty(pool)
        @test isempty(to_remove)
    end

    @testset "tail just below linear threshold (boundary)" begin
        # length(to_remove) == 8 — should use linear path.
        pool = [_mk(Float64(i)) for i in 1:8]
        to_remove = [_mk(Float64(i)) for i in 1:8]
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test length(dropped) == 8
        @test isempty(pool)
        @test isempty(to_remove)
    end

    @testset "no match: pool unchanged, to_remove unchanged" begin
        pool = [_mk(10.0), _mk(20.0)]
        to_remove = [_mk(1.0), _mk(2.0)]
        dropped = TPO._drain_first_matches!(pool, to_remove)
        @test isempty(dropped)
        @test pool == [_mk(10.0), _mk(20.0)]
        @test to_remove == [_mk(1.0), _mk(2.0)]
    end
end
