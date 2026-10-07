using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "TPO.bin_packing_improvement! does not increase cost" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    c0 = cost(sol)

    saved = TPO.bin_packing_improvement!(sol, instance)

    @test is_feasible(sol, instance)
    @test cost(sol) <= c0 + 1e-6
    @test saved >= -1e-6
    @test isapprox(c0 - cost(sol), saved; atol=1e-6)
end

@testset "TPO.bundle_reinsertion_improvement! does not increase cost" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    c0 = cost(sol)

    saved = TPO.bundle_reinsertion_improvement!(sol, instance)

    @test is_feasible(sol, instance)
    @test cost(sol) <= c0 + 1e-6
    @test saved >= -1e-6
    @test isapprox(c0 - cost(sol), saved; atol=1e-6)
    @test saved > 0.0  # on small, reinsertion is expected to improve
end

@testset "local_search! does not increase cost and stays feasible" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    c0 = cost(sol)

    res = local_search!(sol, instance; time_limit=2, rng=MersenneTwister(0))

    @test is_feasible(sol, instance)
    @test cost(sol) <= c0 + 1e-6
    @test isapprox(res.final_cost, cost(sol); atol=1e-6)
    @test res.n_iter >= 1
end

@testset "local_search! without repack keeps cost consistent" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    c0 = cost(sol)

    res = local_search!(
        sol, instance; max_iter=300, allow_repack=false, rng=MersenneTwister(0)
    )

    @test is_feasible(sol, instance)
    @test isapprox(c0 - cost(sol), res.saved; atol=1e-3)
    @test isapprox(res.final_cost, cost(sol); atol=1e-6)
    @test res.n_iter >= 1
    @test res.saved > 0.0
end

@testset "TPO.tentative_best_fit_count parity with compute_bin_assignments_bfd" begin
    using Random
    rng = MersenneTwister(20260522)
    arc_f = BinPackingArcCost(10.0, 100)
    C = LightCommodity{Nothing}
    for trial in 1:20
        n = rand(rng, 5:40)
        items = [
            LightCommodity(;
                origin_id="o",
                destination_id="d",
                size=Float64(rand(rng, 1:100)),
                info=nothing,
            ) for _ in 1:n
        ]
        @test TPO.tentative_best_fit_count(arc_f, items) == length(
            TransportationPlanningOptimization.compute_bin_assignments_bfd(arc_f, items)
        )
    end
end

@testset "_repack_assignment! chooses BFD when BFD strictly beats FFD" begin
    # Divergent input found by random search: capacity 100, sizes below give FFD=11, BFD=10.
    C = LightCommodity{Nothing}
    arc_f = BinPackingArcCost(10.0, 100)
    sizes = [
        75, 95, 28, 95, 1, 28, 60, 11, 10, 30, 65, 27, 52, 8, 7, 94, 98, 60, 16, 86, 20
    ]
    items = C[
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in sizes
    ]

    ffd = TPO.tentative_bin_count(arc_f, items)
    bfd = TPO.tentative_best_fit_count(arc_f, items)
    @test bfd < ffd  # sanity: this input is indeed divergent

    # Pre-install the FFD packing as the current state, then call _repack_assignment!
    # directly. _repack_assignment! only reads `arc.cost`, so a minimal NetworkArc is enough.
    fake_bins = TransportationPlanningOptimization.compute_bin_assignments(arc_f, items)
    slot = TPO.SingleAssignment{C}(items, fake_bins, arc_f.cost_per_bin * length(fake_bins))
    net_arc = NetworkArc(; travel_time_steps=1, cost=arc_f)

    saved = TransportationPlanningOptimization._repack_assignment!(slot, net_arc)
    @test length(slot.bins) == bfd
    @test isapprox(saved, arc_f.cost_per_bin * (ffd - bfd); atol=1e-9)
    @test isapprox(slot.arc_cost, arc_f.cost_per_bin * bfd; atol=1e-9)
end

@testset "_repack_assignment! gates when no improvement is possible" begin
    # If the current bin count already equals min(ffd, bfd), no repack should happen.
    C = LightCommodity{Nothing}
    arc_f = BinPackingArcCost(10.0, 100)
    items = C[
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in [60, 50, 40, 30, 20]
    ]
    bins = TransportationPlanningOptimization.compute_bin_assignments(arc_f, items)
    slot = TPO.SingleAssignment{C}(items, bins, arc_f.cost_per_bin * length(bins))
    bins_id = objectid(slot.bins)
    net_arc = NetworkArc(; travel_time_steps=1, cost=arc_f)

    saved = TransportationPlanningOptimization._repack_assignment!(slot, net_arc)
    @test saved == 0.0
    @test objectid(slot.bins) == bins_id  # gate: bins object not replaced
end

@testset "TPO.bundle_reinsertion_improvement! cost_threshold filter" begin
    instance = TestFixtures.small_instance()

    sol_no_filter = TestFixtures.small_greedy()
    saved_no_filter = TPO.bundle_reinsertion_improvement!(sol_no_filter, instance)

    sol_filtered = TestFixtures.small_greedy()
    huge_threshold = 1e12  # filter everything
    saved_filtered = TPO.bundle_reinsertion_improvement!(
        sol_filtered, instance; cost_threshold=huge_threshold
    )
    @test saved_filtered == 0.0  # nothing should pass the filter
    @test is_feasible(sol_filtered, instance)  # untouched solution still feasible

    # A modest threshold should let SOME but not all bundles through
    sol_modest = TestFixtures.small_greedy()
    modest_threshold = 0.5 * saved_no_filter  # roughly half of total improvement
    saved_modest = TPO.bundle_reinsertion_improvement!(
        sol_modest, instance; cost_threshold=modest_threshold
    )
    @test 0 <= saved_modest <= saved_no_filter + 1e-6
end

@testset "local_search! terminates on max_no_improv" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()

    res = local_search!(
        sol,
        instance;
        time_limit=10,
        max_no_improv=10,
        max_iter=500_000,
        rng=MersenneTwister(0),
    )

    @test res.n_no_improv >= 10
    @test res.n_iter < 500_000
    @test is_feasible(sol, instance)
end

@testset "local_search! returns a usable trace" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()

    res = local_search!(
        sol, instance; time_limit=2, sample_every=200, rng=MersenneTwister(0)
    )

    @test length(res.timestamps) == length(res.costs)
    @test length(res.timestamps) == length(res.iters_at_sample)
    @test length(res.timestamps) >= 2
    @test issorted(res.timestamps)
    # costs should never go up between samples (each move has an accept gate
    # and the final repack is non-increasing)
    @test all(res.costs[i + 1] <= res.costs[i] + 1e-6 for i in 1:(length(res.costs) - 1))
    @test isapprox(last(res.costs), cost(sol); atol=1e-6)
end

@testset "local_search! improves greedy and is close to standalone reinsertion on small" begin
    instance = TestFixtures.small_instance()

    sol_solo = TestFixtures.small_greedy()
    TPO.bundle_reinsertion_improvement!(sol_solo, instance)
    cost_solo = cost(sol_solo)

    sol_ls = TestFixtures.small_greedy()
    greedy_cost = cost(sol_ls)
    # Bounded by max_iter (deterministic given the fixed rng), not by the
    # clock. 5000 iterations run in low tens of seconds, time_limit is a
    # generous safety cap only and must never be the binding constraint.
    res = local_search!(
        sol_ls,
        instance;
        max_iter=5000,
        time_limit=120,
        cost_threshold_relative=0.0,
        rng=MersenneTwister(0),
    )
    cost_ls = cost(sol_ls)

    # Rejected moves are restored exactly: the accepted savings add up to the cost change,
    # and every bin holds exactly the commodities of its slot.
    @test cost_ls ≈ greedy_cost - res.saved rtol = 1e-9
    @test is_feasible(sol_ls, instance)
    slots = [
        slot for a in values(sol_ls.assignments) for
        slot in (a isa TPO.SingleAssignment ? [a] : a.per_mode) if !isempty(slot.bins)
    ]
    @test all(
        sort([c.size for b in s.bins for c in b.commodities]) == sort([c.size for c in s.commodities])
        for s in slots
    )
    @test all(!isempty(b.commodities) for s in slots for b in s.bins)

    @test cost_ls < greedy_cost
    @test cost_ls <= cost_solo * (1 + 5e-3)
end

@testset "_try_reinsert_bundle! same-path does not mutate assignments" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    TPO.bundle_reinsertion_improvement!(sol, instance)
    c_before = cost(sol)

    # Try reinserting every bundle. When the result is 0.0 (same path or no
    # path), verify that assignments are unchanged compared to right before
    # the call. Snapshot per-call because a prior successful reinsertion
    # (improved > 0) legitimately changes the state.
    for i in eachindex(instance.bundles)
        isempty(sol.bundle_paths[i]) && continue
        costs_snap = Dict(edge => TPO.cost_of(a) for (edge, a) in sol.assignments)
        sizes_snap = Dict(
            edge => a.total_size for
            (edge, a) in sol.assignments if a isa TPO.SingleAssignment
        )
        improved = TPO._try_reinsert_bundle!(sol, instance, i, TPO.CheapestMode())
        if improved == 0.0
            for (edge, a) in sol.assignments
                @test TPO.cost_of(a) == costs_snap[edge]
                if a isa TPO.SingleAssignment
                    @test a.total_size == sizes_snap[edge]
                end
            end
        end
    end

    @test cost(sol) <= c_before + 1e-6
    @test is_feasible(sol, instance)
end

@testset "_try_reinsert_bundle! cost delta matches cost(sol) change" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()

    rng = MersenneTwister(12345)
    n_bundles = length(instance.bundles)
    for _ in 1:50
        bundle_idx = rand(rng, 1:n_bundles)
        isempty(sol.bundle_paths[bundle_idx]) && continue
        c_before = cost(sol)
        improved = TPO._try_reinsert_bundle!(sol, instance, bundle_idx, TPO.CheapestMode())
        c_after = cost(sol)
        @test improved >= -1e-9
        @test isapprox(c_before - c_after, improved; atol=1e-3)
        @test is_feasible(sol, instance)
    end
end

@testset "bin_packing repack keeps all terms of a SumArcCost slot" begin
    bp = BinPackingArcCost(10.0, 100)
    sum_cost = SumArcCost((bp, LinearArcCost(0.5), LinearArcCost(0.25)))
    comms = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (65, 60, 40, 35)
    ]
    # one commodity per bin: suboptimal packing (4 bins instead of 2)
    bins = reduce(vcat, [TPO.compute_bin_assignments(bp, [c]) for c in comms])
    sorted_comms = sort(comms; by=c -> c.size, rev=true)
    slot = TPO.SingleAssignment{eltype(comms)}(sorted_comms, bins, 0.0)
    slot.sorted = true
    slot.arc_cost = 10.0 * length(bins) + 0.75 * sum(c.size for c in comms)

    before = slot.arc_cost
    @test length(slot.bins) == 4
    saved = TPO._repack_slot!(slot, bp)

    @test length(slot.bins) == 2
    @test saved > 0
    @test slot.arc_cost ≈ before - saved
    @test isapprox(slot.arc_cost, TPO.evaluate(sum_cost, slot.commodities); atol=1e-9)
end

@testset "bin_packing repack dispatches on a NetworkArc with a SumArcCost" begin
    bp = BinPackingArcCost(10.0, 100)
    sum_cost = SumArcCost((bp, LinearArcCost(0.5)))
    arc = NetworkArc(; travel_time_steps=1, capacity=typemax(Int), cost=sum_cost)
    comms = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (65, 60, 40, 35)
    ]
    bins = reduce(vcat, [TPO.compute_bin_assignments(bp, [c]) for c in comms])
    slot = TPO.SingleAssignment{eltype(comms)}(
        sort(comms; by=c -> c.size, rev=true), bins, 0.0
    )
    slot.sorted = true
    # price the 4 one-commodity bins by hand (evaluate would repack optimally)
    slot.arc_cost = 10.0 * length(bins) + 0.5 * sum(c.size for c in comms)
    before = slot.arc_cost

    saved = TPO._repack_assignment!(slot, arc)

    @test saved > 0
    @test slot.arc_cost <= before
    @test slot.arc_cost ≈ before - saved
    @test isapprox(slot.arc_cost, TPO.evaluate(sum_cost, slot.commodities); atol=1e-9)
end

@testset "bin_packing_improvement! keeps cost consistent on SumArcCost bin-packing arcs" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    arcs = [
        TPO.tsg_edge_arc(instance.index_cache, e[1], e[2]) for e in keys(sol.assignments)
    ]
    @test any(a -> a isa NetworkArc && a.cost isa SumArcCost, arcs)
    c0 = cost(sol)
    # (slot, cost_per_bin, bins before) for every slot with a bin-packing term.
    packed = [
        (slot, bp.cost_per_bin, length(slot.bins)) for (slot, bp) in (
            (
                s,
                TPO._bin_packing_cost_of(TPO.tsg_edge_arc(instance.index_cache, e...).cost),
            ) for (e, s) in sol.assignments
        ) if bp !== nothing
    ]
    saved = TPO.bin_packing_improvement!(sol, instance)
    freed = sum(cpb * (n0 - length(s.bins)) for (s, cpb, n0) in packed)
    @test any(t -> length(t[1].bins) < t[3], packed)
    @test saved ≈ freed atol = 1e-6
    @test saved >= -1e-6
    @test cost(sol) <= c0 + 1e-6
    @test isapprox(c0 - saved, cost(sol); atol=1e-6)
    @test is_feasible(sol, instance)
end

@testset "is_feasible rejects an empty bin on a bin-packing arc" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    @test is_feasible(sol, instance)
    slot = first(
        s for (e, s) in sol.assignments if !isempty(s.bins) &&
            TPO._bin_packing_cost_of(TPO.tsg_edge_arc(instance.index_cache, e...).cost) !==
            nothing
    )
    push!(slot.bins, TPO.Bin(similar(slot.commodities, 0), 100.0))
    @test_logs (:warn, r"empty bin") match_mode = :any @test !is_feasible(
        sol, instance; verbose=true
    )
end

@testset "local_search! with refine_two_node=true keeps the cost consistent" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    c0 = cost(sol)
    res = local_search!(
        sol,
        instance;
        refine_two_node=true,
        allow_reintro=false,
        max_iter=200,
        rng=MersenneTwister(7),
    )
    @test res.n_iter >= 1
    @test is_feasible(sol, instance)
    @test isapprox(c0 - res.saved, cost(sol); atol=1e-6)
end
