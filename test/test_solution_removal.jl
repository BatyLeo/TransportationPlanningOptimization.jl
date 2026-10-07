using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures
using .TestFixtures: same_state, edge_multisets

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

@testset "TPO.remove_bundle_path! then add_bundle_path! in greedy order restores the state" begin
    instance = TestFixtures.tiny_instance()
    sol = greedy_heuristic(instance; show_progress=false)
    original = deepcopy(sol)
    saved_paths = [copy(p) for p in sol.bundle_paths]

    for i in eachindex(saved_paths)
        TPO.remove_bundle_path!(sol, instance, i)
    end
    @test all(isempty, sol.bundle_paths)
    @test isapprox(cost(sol), 0.0; atol=1e-6)

    # Frozen packing grows the bins in insertion order, so the greedy order is replayed.
    for i in sortperm(instance.bundles; by=TPO.max_pack_size, rev=true)
        TPO.add_bundle_path!(sol, instance, i, copy(saved_paths[i]))
    end
    @test same_state(sol, original)
    @test cost(sol) == cost(original)
    @test is_feasible(sol, instance; verbose=true)
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
    # 9 removed copies take the multiset path of `_remove_from_bins!`.
    remove_in_place!(slot, arc_f, slot.commodities[1:9])
    @test length(slot.commodities) == 6
    @test bins_consistent(slot, arc_f)
    @test length(slot.bins) == 1
end

@testset "multiset bin removal matches the per-bin removal" begin
    arc_f = BinPackingArcCost(10.0, 100)
    rng = MersenneTwister(11)
    slot = packed_slot(rand(rng, [10.0, 20.0, 30.0], 40); arc_f)
    removed = slot.commodities[1:2:20]
    @test length(removed) > TPO.LINEAR_REMOVAL_MAX
    bins_a = [TPO.Bin(copy(b.commodities), b.remaining_capacity) for b in slot.bins]
    bins_b = [TPO.Bin(copy(b.commodities), b.remaining_capacity) for b in slot.bins]
    working = copy(removed)
    for bin in bins_a
        isempty(working) && break
        TPO._remove_from_bin!(bin.commodities, working) || continue
        bin.remaining_capacity = 100.0 - sum(c.size for c in bin.commodities; init=0.0)
    end
    TPO._remove_from_bins_multiset!(bins_b, removed, 100.0)
    @test isempty(working)
    @test [b.commodities for b in bins_a] == [b.commodities for b in bins_b]
    @test [b.remaining_capacity for b in bins_a] == [b.remaining_capacity for b in bins_b]
end

@testset "vacated edges cost like never-used edges and hold no size residue" begin
    instance = TestFixtures.small_instance()
    sol = greedy_heuristic(instance; show_progress=false)
    paths = [copy(p) for p in sol.bundle_paths]
    for i in eachindex(paths)
        TPO.remove_bundle_path!(sol, instance, i)
    end
    @test !isempty(sol.assignments)
    @test all(
        a -> all(s -> s.total_size == 0.0, TestFixtures.slots(a)), values(sol.assignments)
    )
    fresh = TPO.SolutionState(instance)
    for (i, path) in enumerate(paths), k in 1:(length(path) - 1)
        args = (instance, instance.bundles[i], path[k], path[k + 1])
        counts = TPO.empty_pack_counts(
            instance, instance.bundles[i], instance.travel_time_graph.bundle_arcs[i]
        )
        @test TPO.compute_ttg_edge_incremental_cost(sol, args...; empty_counts=counts) ===
            TPO.compute_ttg_edge_incremental_cost(fresh, args...)
    end
end

@testset "slice removal and re-add match whole-path removal and restore the state" begin
    for wrap_time in (true, false)
        instance = TestFixtures.small_instance(; wrap_time)
        base = greedy_heuristic(instance; show_progress=false)
        long = findall(p -> length(p) >= 3, base.bundle_paths)
        @test !isempty(long)
        for b in first(long, 3)
            path = copy(base.bundle_paths[b])
            n = length(path)

            whole = deepcopy(base)
            sliced = deepcopy(base)
            @test TPO.remove_bundle_path!(whole, instance, b) ==
                TPO.remove_bundle_subpath!(sliced, instance, b, 1, n)
            @test sliced.bundle_paths[b] == path
            @test edge_multisets(whole) == edge_multisets(sliced)

            for (lo, hi) in ((1, n), (2, n), (1, n - 1), (2, n - 1))
                sol = deepcopy(base)
                removed = TPO.remove_bundle_subpath!(sol, instance, b, lo, hi)
                @test removed <= 0
                added = TPO.add_bundle_subpath!(sol, instance, b, copy(path), lo, hi)
                @test sol.bundle_paths[b] == path
                @test edge_multisets(sol) == edge_multisets(base)
                @test cost(sol) ≈ cost(base) + removed + added atol = 1e-6
            end
        end
    end
end

@testset "swapping slices between bundles matches a rebuild from the paths" begin
    for wrap_time in (true, false)
        instance = TestFixtures.small_instance(; wrap_time)
        spatial = instance.index_cache.ttg_code_to_spatial_code
        base = greedy_heuristic(instance; show_progress=false)
        found = false
        for p in base.bundle_paths, k in 1:(length(p) - 1), l in (k + 1):length(p)
            lifted = TPO.bundles_through_nodes(base, p[k], p[l])
            length(lifted) >= 2 || continue
            (i, lo_i, hi_i), (j, lo_j, hi_j) = lifted[1], lifted[2]
            pi_, pj = base.bundle_paths[i], base.bundle_paths[j]
            new_i = vcat(pi_[1:(lo_i - 1)], pj[lo_j:hi_j], pi_[(hi_i + 1):end])
            new_j = vcat(pj[1:(lo_j - 1)], pi_[lo_i:hi_i], pj[(hi_j + 1):end])
            pi_ == new_i && continue
            all(q -> TPO.is_elementary_path(q, spatial), (new_i, new_j)) || continue
            found = true

            sol = deepcopy(base)
            delta = TPO.remove_bundle_subpath!(sol, instance, i, lo_i, hi_i)
            delta += TPO.remove_bundle_subpath!(sol, instance, j, lo_j, hi_j)
            delta += TPO.add_bundle_subpath!(
                sol, instance, i, new_i, lo_i, lo_i + length(pj[lo_j:hi_j]) - 1
            )
            delta += TPO.add_bundle_subpath!(
                sol, instance, j, new_j, lo_j, lo_j + length(pi_[lo_i:hi_i]) - 1
            )
            rebuilt = TPO.SolutionState(sol.bundle_paths, instance)
            @test edge_multisets(sol) == edge_multisets(rebuilt)
            @test cost(sol) ≈ cost(base) + delta atol = 1e-6
            @test is_feasible(sol, instance; verbose=true)
            break
        end
        @test found
    end
end

@testset "batched slice removal matches sequential removal and rolls back exactly" begin
    instance = TestFixtures.small_instance()
    base = greedy_heuristic(instance; show_progress=false)
    best = NTuple{3,Int}[]
    for p in base.bundle_paths, k in 1:(length(p) - 1), l in (k + 1):length(p)
        lifted = TPO.bundles_through_nodes(base, p[k], p[l])
        length(lifted) > length(best) && (best = lifted)
    end
    @test length(best) >= 2

    sequential = deepcopy(base)
    for (i, lo, hi) in best
        TPO.remove_bundle_subpath!(sequential, instance, i, lo, hi)
    end
    batched = deepcopy(base)
    old_paths = [batched.bundle_paths[i] for (i, _, _) in best]
    i1, lo1, hi1 = first(best)
    snapshots = TPO._snapshot_path_assignments(
        batched, instance, i1, view(batched.bundle_paths[i1], lo1:hi1)
    )
    for (i, lo, hi) in best[2:end]
        TPO._snapshot_path_assignments(
            batched,
            instance,
            i,
            view(batched.bundle_paths[i], lo:hi);
            cache=snapshots,
            clear=false,
        )
    end
    delta = TPO.remove_bundle_subpaths!(batched, instance, best)
    @test delta < 0
    @test edge_multisets(batched) == edge_multisets(sequential)
    @test cost(batched) ≈ cost(base) + delta atol = 1e-6

    TPO._restore_multi_bundle_assignments!(
        batched, [i for (i, _, _) in best], old_paths, snapshots
    )
    @test same_state(batched, base)
end

@testset "batched slice removal on a MultiAssignment edge matches whole-path removal" begin
    modes = [(BinPackingArcCost(10.0, 2), 1, 3), (BinPackingArcCost(7.0, 2), 1, 10)]
    instance = TestFixtures._leg_instance(modes, 1; quantity=5)
    base = greedy_heuristic(
        instance; mode_selector=FillThenSpillMode(), show_progress=false
    )
    @test only(values(base.assignments)) isa TPO.MultiAssignment
    path = base.bundle_paths[1]
    whole = deepcopy(base)
    batched = deepcopy(base)
    delta = TPO.remove_bundle_subpaths!(batched, instance, [(1, 1, length(path))])
    @test delta == TPO.remove_bundle_path!(whole, instance, 1)
    @test edge_multisets(batched) == edge_multisets(whole)
    @test cost(batched) ≈ cost(base) + delta atol = 1e-9
end
