using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "TPO.remove_bundle_path! on tiny instance" begin
    instance = TestFixtures.tiny_instance()
    sol = TestFixtures.tiny_greedy()

    @test cost(sol) > 0
    @test !isempty(sol.bundle_paths[1])
    saved_path = copy(sol.bundle_paths[1])

    TPO.remove_bundle_path!(sol, instance, 1)
    @test isempty(sol.bundle_paths[1])

    TPO.add_bundle_path!(sol, instance, 1, saved_path)
    @test sol.bundle_paths[1] == saved_path
end

@testset "TPO.remove_bundle_path! preserves cost after add-remove-add cycle" begin
    instance = TestFixtures.tiny_instance()
    # The round-trip cost-preservation invariant holds only under
    # order-independent packing. `TPO.remove_bundle_path!` works in place: it
    # drops the removed commodities from their bins and re-packs with FFD only
    # when that strictly lowers the bin count. Re-adding with `:ffd_union`
    # re-packs each arc's full commodity set from scratch, so after all bundles
    # are back every arc holds the same FFD packing as the `:ffd_union` greedy,
    # whatever bins the removals left. The production default (`:frozen`) grows
    # cached bins in insertion order, so the same round trip could legitimately
    # change the bin counts.
    sol = greedy_heuristic(instance; packing=:ffd_union, show_progress=false)
    c_before = cost(sol)
    saved_paths = [copy(p) for p in sol.bundle_paths]

    for i in eachindex(saved_paths)
        TPO.remove_bundle_path!(sol, instance, i)
    end
    @test all(isempty, sol.bundle_paths)
    @test isapprox(cost(sol), 0.0; atol=1e-6)

    for i in eachindex(saved_paths)
        TPO.add_bundle_path!(sol, instance, i, saved_paths[i]; packing=:ffd_union)
    end
    @test isapprox(cost(sol), c_before; atol=1e-6)
end

@testset "TPO.remove_bundle_path! on MultiModalArc add-remove-add cycle" begin
    # Two parallel modes with the same transit time collapse to a single
    # MultiModalArc edge in the TSG, exercising the MultiAssignment dispatch
    # of _remove_commodities_from_assignment!.
    nodes = [Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination)]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=1,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(10.0),
            travel_time=Day(1),
            capacity=10,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=2,
            departure_date=DateTime(2024, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode(), show_progress=false)
    @test is_feasible(sol, instance)

    c_before = cost(sol)
    saved_path = copy(sol.bundle_paths[1])
    @test !isempty(saved_path)

    TPO.remove_bundle_path!(sol, instance, 1)
    @test isempty(sol.bundle_paths[1])
    @test isapprox(cost(sol), 0.0; atol=1e-6)

    TPO.add_bundle_path!(sol, instance, 1, saved_path; mode_selector=FillThenSpillMode())
    @test sol.bundle_paths[1] == saved_path
    @test isapprox(cost(sol), c_before; atol=1e-6)
end

@testset "double TPO.remove_bundle_path! is a no-op" begin
    instance = TestFixtures.tiny_instance()
    sol = TestFixtures.tiny_greedy()
    c_before = cost(sol)

    TPO.remove_bundle_path!(sol, instance, 1)
    cost_once = cost(sol)
    TPO.remove_bundle_path!(sol, instance, 1)
    cost_twice = cost(sol)

    @test isapprox(cost_once, cost_twice; atol=1e-6)
    @test isempty(sol.bundle_paths[1])
end

@testset "partial removal makes solution infeasible" begin
    instance = TestFixtures.tiny_instance()
    sol = TestFixtures.tiny_greedy()
    @test is_feasible(sol, instance)

    TPO.remove_bundle_path!(sol, instance, 1)
    @test !is_feasible(sol, instance; verbose=false)
end

@testset "TPO.add_bundle_path! and TPO.remove_bundle_path! return cost deltas" begin
    instance = TestFixtures.tiny_instance()
    sol = TestFixtures.tiny_greedy()
    c0 = cost(sol)
    saved_path = copy(sol.bundle_paths[1])

    removed_delta = TPO.remove_bundle_path!(sol, instance, 1)
    c1 = cost(sol)
    @test isapprox(removed_delta, c1 - c0; atol=1e-6)
    @test removed_delta <= 1e-9  # non-positive (allow tiny FP slack)

    added_delta = TPO.add_bundle_path!(sol, instance, 1, saved_path)
    c2 = cost(sol)
    @test isapprox(added_delta, c2 - c1; atol=1e-6)
    @test added_delta >= -1e-9

    @test isapprox(c2, c0; atol=1e-6)
end

# Slot of `sizes` packed with FFD on a bin-packing arc of capacity 100.
function packed_slot(sizes; arc_f=BinPackingArcCost(10.0, 100))
    C = LightCommodity{Nothing}
    comms = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in sizes
    ]
    slot = TPO.SingleAssignment{C}(comms, TPO.Bin{C}[], 0.0)
    TPO._update_single_assignment_cost!(slot, arc_f)
    return slot
end

function remove_in_place!(slot, arc_f, removed)
    TPO._remove_all_from_pool!(slot.commodities, removed)
    slot.total_size -= sum(c.size for c in removed; init=0.0)
    TPO._update_cost_after_removal!(slot, arc_f, removed)
    return slot
end

function bins_consistent(slot, arc_f; cost=arc_f.cost_per_bin * length(slot.bins))
    binned = sort([c.size for b in slot.bins for c in b.commodities]; rev=true)
    return binned == sort([c.size for c in slot.commodities]; rev=true) &&
           all(!isempty(b.commodities) for b in slot.bins) &&
           all(
               b.remaining_capacity ≈ 100 - sum(c.size for c in b.commodities) for
               b in slot.bins
           ) &&
           slot.arc_cost ≈ cost
end

@testset "in-place removal keeps bin contents exact and drops empty bins" begin
    arc_f = BinPackingArcCost(10.0, 100)
    slot = packed_slot([70, 60, 40, 35, 25]; arc_f)
    @test length(slot.bins) == 3
    kept = [b for b in slot.bins if length(b.commodities) == 2]
    lone = only(c for b in slot.bins if length(b.commodities) == 1 for c in b.commodities)
    remove_in_place!(slot, arc_f, [lone])
    @test length(slot.bins) == 2
    @test bins_consistent(slot, arc_f)
    # at the lower bound: the surviving bins are the same objects
    @test all(any(b === k for k in kept) for b in slot.bins)
end

@testset "in-place removal repacks only when strictly better" begin
    arc_f = BinPackingArcCost(10.0, 100)
    # four bins of one 60 each: removing one leaves 3 bins, above the lower bound (2)
    # but first-fit-decreasing needs 3 as well, so the bins are kept
    slot = packed_slot([60, 60, 60, 60]; arc_f)
    old_bins = copy(slot.bins)
    remove_in_place!(slot, arc_f, [first(slot.commodities)])
    @test length(slot.bins) == 3
    @test all(slot.bins .=== [b for b in old_bins if !isempty(b.commodities)])
    @test bins_consistent(slot, arc_f)

    # fragmented bins [65], [60], [40], [35]: removing 35 leaves [65], [60], [40] and first-fit
    # decreasing needs only 2
    comms = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (65, 60, 40, 35)
    ]
    bins = reduce(vcat, [TPO.compute_bin_assignments(arc_f, [c]) for c in comms])
    slot = TPO.SingleAssignment{eltype(comms)}(copy(comms), bins, 40.0)
    slot.sorted = true
    remove_in_place!(slot, arc_f, [comms[4]])
    @test length(slot.bins) == 2
    @test bins_consistent(slot, arc_f)
end

@testset "in-place removal never raises the bin count" begin
    rng = MersenneTwister(7)
    bp = BinPackingArcCost(10.0, 100)
    for arc_f in (bp, SumArcCost((LinearArcCost(0.5), bp)))
        terms = arc_f isa SumArcCost ? arc_f.terms : (arc_f,)
        for _ in 1:50
            slot = packed_slot(rand(rng, 5:95, 12); arc_f)
            while !isempty(slot.commodities)
                n = length(slot.bins)
                remove_in_place!(slot, arc_f, [rand(rng, slot.commodities)])
                @test length(slot.bins) <= n
                @test length(slot.bins) <= TPO.tentative_bin_count(bp, slot.commodities)
                @test bins_consistent(slot, bp; cost=TPO._sum_packed_cost(slot, terms))
            end
            @test isempty(slot.bins)
        end
    end
end

@testset "in-place removal of many equal duplicates in one call" begin
    arc_f = BinPackingArcCost(10.0, 100)
    slot = packed_slot(fill(10.0, 15); arc_f)
    # 9 removed copies exceed the small-vector threshold of `_remove_from_bin!`.
    remove_in_place!(slot, arc_f, slot.commodities[1:9])
    @test length(slot.commodities) == 6
    @test bins_consistent(slot, arc_f)
    @test length(slot.bins) == 1
end
