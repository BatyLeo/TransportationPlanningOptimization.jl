using Test
using Dates
using TransportationPlanningOptimization

const TPO = TransportationPlanningOptimization

@testset "SumArcCost evaluate sums over terms" begin
    items = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (10.0, 20.0, 30.0)
    ]
    linear = LinearArcCost(2.0)
    sum_cost = SumArcCost((linear, linear))
    @test isapprox(
        TPO.evaluate(sum_cost, items), 2 * TPO.evaluate(linear, items); atol=1e-9
    )
end

@testset "SumArcCost incremental sums over terms" begin
    C = LightCommodity{Nothing}
    existing = C[]
    new = [LightCommodity(; origin_id="o", destination_id="d", size=5.0, info=nothing)]
    sum_cost = SumArcCost((LinearArcCost(1.0), LinearArcCost(3.0)))
    @test isapprox(TPO.incremental_cost(sum_cost, existing, new), 20.0; atol=1e-9)
end

@testset "SumArcCost bin-packing delegates to unique BinPackingArcCost" begin
    items = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (40.0, 60.0, 35.0)
    ]
    bp = BinPackingArcCost(10.0, 100)
    sum_cost = SumArcCost((bp, LinearArcCost(1.0)))
    @test TPO.tentative_bin_count(sum_cost, items) == TPO.tentative_bin_count(bp, items)
    @test length(TPO.compute_bin_assignments(sum_cost, items)) ==
        length(TPO.compute_bin_assignments(bp, items))
end

@testset "SumArcCost errors on empty / missing BP / multi BP" begin
    @test_throws ArgumentError SumArcCost(())
    bp = BinPackingArcCost(10.0, 100)
    sum_no_bp = SumArcCost((LinearArcCost(2.0),))
    @test_throws ArgumentError TPO.compute_bin_assignments(
        sum_no_bp, LightCommodity{Nothing}[]
    )
    sum_two_bp = SumArcCost((bp, bp))
    @test_throws ArgumentError TPO.tentative_bin_count(
        sum_two_bp, LightCommodity{Nothing}[]
    )
end

@testset "Arc constructor accepts single cost (unchanged behavior)" begin
    bp = BinPackingArcCost(10.0, 100)
    arc = Arc(; origin_id="o", destination_id="d", cost=bp, travel_time=Day(1))
    @test arc.cost === bp
end

@testset "Arc constructor accepts single-element tuple (unwrapped)" begin
    bp = BinPackingArcCost(10.0, 100)
    arc = Arc(; origin_id="o", destination_id="d", cost=(bp,), travel_time=Day(1))
    @test arc.cost === bp
end

@testset "Arc constructor wraps multi-tuple into SumArcCost" begin
    bp = BinPackingArcCost(10.0, 100)
    linear = LinearArcCost(0.5)
    arc = Arc(; origin_id="o", destination_id="d", cost=(bp, linear), travel_time=Day(1))
    @test arc.cost isa SumArcCost
    @test arc.cost.terms === (bp, linear)
end

@testset "Arc constructor errors on empty cost tuple" begin
    @test_throws ArgumentError Arc(;
        origin_id="o", destination_id="d", cost=(), travel_time=Day(1)
    )
end

@testset "SumArcCost slot cost reuses the packed bins and caches the dirty count" begin
    C = LightCommodity{Nothing}
    items = C[
        LightCommodity(; origin_id="o", destination_id="d", size=s, info=nothing) for
        s in (40.0, 60.0, 35.0, 25.0, 70.0)
    ]
    bp = BinPackingArcCost(10.0, 100)
    new = sort(
        [LightCommodity(; origin_id="o", destination_id="d", size=30.0, info=nothing)];
        by=c -> -c.size,
    )
    for arc_f in (
        SumArcCost((bp, LinearArcCost(0.3))),
        SumArcCost((LinearArcCost(0.3), bp)),
        SumArcCost((LinearArcCost(0.3), bp, LinearArcCost(0.7))),
    )
        slot = TPO.SingleAssignment{C}(copy(items), TPO.Bin{C}[], 0.0)
        slot.total_size = sum(c.size for c in items)
        TPO._update_single_assignment_cost!(slot, arc_f)
        @test slot.arc_cost === TPO.evaluate(arc_f, slot.commodities; presorted=true)

        # Removal path: cached FFD count, and the dirty-slot increment matches the uncached one
        popfirst!(slot.commodities)
        slot.total_size = sum(c.size for c in slot.commodities)
        TPO._update_cost_skip_bins!(slot, arc_f)
        @test slot.bins_dirty
        @test slot.dirty_bin_count == TPO.tentative_bin_count(bp, slot.commodities)
        @test slot.arc_cost === TPO.evaluate(arc_f, slot.commodities; presorted=true)
        buffer = TPO.BinPackingBuffer()
        @test TPO._frozen_edge_incremental_cost(buffer, arc_f, slot, new) ===
            TPO.incremental_cost!(buffer, arc_f, slot.commodities, new)
    end
end
