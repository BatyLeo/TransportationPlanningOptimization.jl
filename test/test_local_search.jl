using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

@testset "TPO.bin_packing_improvement! does not increase cost" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    c0 = cost(sol)

    saved = TPO.bin_packing_improvement!(sol, instance)

    @test is_feasible(sol, instance)
    @test cost(sol) <= c0 + 1e-6
    @test saved >= -1e-6
    @test isapprox(c0 - cost(sol), saved; atol=1e-6)
end

@testset "TPO.bundle_reinsertion_improvement! does not increase cost" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    c0 = cost(sol)

    saved = TPO.bundle_reinsertion_improvement!(sol, instance)

    @test is_feasible(sol, instance)
    @test cost(sol) <= c0 + 1e-6
    @test saved >= -1e-6
    @test isapprox(c0 - cost(sol), saved; atol=1e-6)
end

@testset "TPO.bundle_reinsertion_improvement! saved matches cost(sol) delta for small" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    c0 = cost(sol)
    saved = TPO.bundle_reinsertion_improvement!(sol, instance)
    @test isapprox(c0 - cost(sol), saved; atol=1e-3)
    @test saved > 0.0  # on small, reinsertion is expected to improve (~84k from earlier benchmark)
end

@testset "local_search! does not increase cost and stays feasible" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    c0 = cost(sol)

    res = local_search!(sol, instance; time_limit=10, rng=MersenneTwister(0))

    @test is_feasible(sol, instance)
    @test cost(sol) <= c0 + 1e-6
    @test isapprox(res.final_cost, cost(sol); atol=1e-6)
    @test res.n_iter >= 1
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
    @test isapprox(slot.cost, arc_f.cost_per_bin * bfd; atol=1e-9)
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
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    sol_no_filter = greedy_heuristic(instance)
    saved_no_filter = TPO.bundle_reinsertion_improvement!(sol_no_filter, instance)

    sol_filtered = greedy_heuristic(instance)
    huge_threshold = 1e12  # filter everything
    saved_filtered = TPO.bundle_reinsertion_improvement!(
        sol_filtered, instance; cost_threshold=huge_threshold
    )
    @test saved_filtered == 0.0  # nothing should pass the filter
    @test is_feasible(sol_filtered, instance)  # untouched solution still feasible

    # A modest threshold should let SOME but not all bundles through
    sol_modest = greedy_heuristic(instance)
    modest_threshold = 0.5 * saved_no_filter  # roughly half of total improvement
    saved_modest = TPO.bundle_reinsertion_improvement!(
        sol_modest, instance; cost_threshold=modest_threshold
    )
    @test 0 <= saved_modest <= saved_no_filter + 1e-6
end

@testset "local_search! terminates on max_no_improv" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)

    res = local_search!(
        sol,
        instance;
        time_limit=60,
        max_no_improv=10,
        max_iter=500_000,
        rng=MersenneTwister(0),
    )

    @test res.n_no_improv >= 10
    @test res.n_iter < 500_000
    @test is_feasible(sol, instance)
end

@testset "local_search! returns a usable trace" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)

    res = local_search!(
        sol, instance; time_limit=5, sample_every=200, rng=MersenneTwister(0)
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

@testset "local_search! reaches at least standalone reinsertion cost on small" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    sol_solo = greedy_heuristic(instance)
    TPO.bundle_reinsertion_improvement!(sol_solo, instance)
    cost_solo = cost(sol_solo)

    sol_ls = greedy_heuristic(instance)
    local_search!(
        sol_ls,
        instance;
        time_limit=120,
        cost_threshold_relative=0.0,
        rng=MersenneTwister(0),
    )
    cost_ls = cost(sol_ls)

    # LS should never be worse than a single full reinsertion sweep
    # (random reinsertion plus two-node consolidation plus a final repack
    # can only improve the cost beyond a one-pass reinsertion).
    @test cost_ls <= cost_solo + 1e-6
end
