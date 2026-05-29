using Test
using TransportationPlanningOptimization
using Dates
const TPO = TransportationPlanningOptimization

function _mk(size::Float64, sup::String="S", cust::String="C")
    return TPO.LightCommodity(;
        origin_id=sup, destination_id=cust, size=size, info=nothing,
    )
end

const LC = typeof(_mk(1.0))

function _slot(comms::Vector{LC}; sorted::Bool=true)
    return TPO.SingleAssignment{LC}(comms, TPO.Bin{LC}[], 0.0, sorted)
end

# Sizes of `slot.commodities` in descending order means: sorted_desc(slot) ↔ all neighbors satisfy >=.
_is_desc(v) = all(v[i].size >= v[i+1].size for i in 1:(length(v)-1))

@testset "_merge_sorted_into_slot! contract" begin
    @testset "no-op on empty new_commodities" begin
        slot = _slot([_mk(10.0), _mk(5.0)])
        TPO._merge_sorted_into_slot!(slot, LC[])
        @test slot.commodities == [_mk(10.0), _mk(5.0)]
        @test slot.sorted
    end

    @testset "into empty slot, copies sorted new" begin
        slot = _slot(LC[])
        new = [_mk(10.0), _mk(5.0), _mk(2.0)]  # desc
        TPO._merge_sorted_into_slot!(slot, new)
        @test slot.commodities == new
        @test slot.sorted
        @test _is_desc(slot.commodities)
    end

    @testset "merge interleaved (basic correctness)" begin
        slot = _slot([_mk(10.0), _mk(5.0), _mk(2.0)])
        new = [_mk(12.0), _mk(7.0), _mk(3.0)]
        TPO._merge_sorted_into_slot!(slot, new)
        @test [c.size for c in slot.commodities] == [12.0, 10.0, 7.0, 5.0, 3.0, 2.0]
        @test slot.sorted
        @test _is_desc(slot.commodities)
    end

    @testset "merge where all new are smaller (no read/write conflict)" begin
        slot = _slot([_mk(100.0), _mk(50.0), _mk(20.0)])
        new = [_mk(10.0), _mk(5.0), _mk(1.0)]
        TPO._merge_sorted_into_slot!(slot, new)
        @test [c.size for c in slot.commodities] == [100.0, 50.0, 20.0, 10.0, 5.0, 1.0]
        @test slot.sorted
    end

    @testset "merge where all new are larger" begin
        slot = _slot([_mk(10.0), _mk(5.0), _mk(1.0)])
        new = [_mk(100.0), _mk(50.0), _mk(20.0)]
        TPO._merge_sorted_into_slot!(slot, new)
        @test [c.size for c in slot.commodities] == [100.0, 50.0, 20.0, 10.0, 5.0, 1.0]
        @test slot.sorted
    end

    @testset "merge with equal sizes (stable behavior)" begin
        slot = _slot([_mk(10.0), _mk(5.0)])
        new = [_mk(10.0), _mk(5.0)]
        TPO._merge_sorted_into_slot!(slot, new)
        @test sort([c.size for c in slot.commodities]; rev=true) ==
              [c.size for c in slot.commodities]
        @test length(slot.commodities) == 4
        @test slot.sorted
    end

    @testset "single-element merges" begin
        slot = _slot([_mk(10.0), _mk(5.0)])
        TPO._merge_sorted_into_slot!(slot, [_mk(7.0)])
        @test [c.size for c in slot.commodities] == [10.0, 7.0, 5.0]
        @test slot.sorted
    end

    @testset "fallback path when slot.sorted=false" begin
        # If we ever build a slot with sorted=false (test helpers, ad-hoc construction),
        # the function must not silently produce wrong results. It just appends.
        slot = _slot([_mk(5.0), _mk(10.0)]; sorted=false)
        TPO._merge_sorted_into_slot!(slot, [_mk(7.0)])
        @test length(slot.commodities) == 3
        @test !slot.sorted  # stays false (correctness, not optimization)
    end

    @testset "large merge stress (random sizes)" begin
        slot = _slot(sort([_mk(rand() * 100) for _ in 1:200], by=c->c.size, rev=true))
        new = sort([_mk(rand() * 100) for _ in 1:50], by=c->c.size, rev=true)
        expected_sizes = sort(vcat([c.size for c in slot.commodities],
                                   [c.size for c in new]); rev=true)
        TPO._merge_sorted_into_slot!(slot, new)
        @test [c.size for c in slot.commodities] == expected_sizes
        @test slot.sorted
    end
end
