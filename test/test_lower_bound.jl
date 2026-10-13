using Test
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound:
    parse_inbound_instance, StockArcCost, InboundCommodityInfo
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "lower_bound produces a feasible solution with non-empty paths" begin
    # Note: `cost(lb_sol)` is the cost of the path set `lower_bound` mutated as
    # a byproduct of computing the LB cost matrix. The LB itself is the sum of
    # Dijkstra distances, not `cost(lb_sol)`. The path set is inserted in
    # `eachindex` order without size-decreasing reordering, so its post-
    # insertion cost can exceed greedy on small instances (observed +22% on
    # `small`, +50% on `tiny` after the direct-arc-ceil fix). We therefore do
    # not assert `cost(lb_sol) <= cost(greedy_sol)` here.
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    lb_sol = lower_bound(instance; show_progress=false)

    @test is_feasible(lb_sol, instance)
    @test all(!isempty, lb_sol.bundle_paths)
    @test isfinite(cost(lb_sol))
end

@testset "lower_bound_filtering leaves at least all multi-hop bundles" begin
    # `tiny` has a multi-hop bundle under `lower_bound_filtering` (verified: all
    # 4 bundles keep a path with length > 2), so the assertion below still
    # holds without needing `small`'s scale.
    instance = TestFixtures.tiny_instance()
    filt = lower_bound_filtering(instance; show_progress=false)

    @test all(!isempty, filt.bundle_paths)
    # On tiny, at least some bundle should choose a multi-hop path
    @test any(
        TPO._direct_arc_position(instance.index_cache, p) == 0 for p in filt.bundle_paths
    )
end

# Two same-OD commodities of size 3, split into two bundles by a custom `group_by`,
# on an A->B arc of capacity `cap`, optionally with an A->H->B detour via a hub.
function two_bundle_direct_instance(cap; with_hub::Bool)
    nodes = [Node(; id="A"), Node(; id="B")]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=cap,
        ),
    ]
    if with_hub
        push!(nodes, Node(; id="H"))
        for (o, d) in (("A", "H"), ("H", "B"))
            push!(
                arcs,
                Arc(;
                    origin_id=o,
                    destination_id=d,
                    cost=LinearArcCost(1.0),
                    travel_time=Day(1),
                    capacity=100,
                ),
            )
        end
    end
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(with_hub ? 2 : 1),
            size=3.0,
            info="p$k",
        ) for k in 1:2
    ]
    return Instance(nodes, arcs, commodities, Day(1); group_by=c -> c.info)
end

@testset "lower_bound_filtering fixes bundles jointly within the hard capacities" begin
    # `lower_bound` prices bundles independently, but filtering must not fix
    # bundles on one arc beyond its capacity: the second bundle is kept and
    # re-solved, here through the hub.
    instance = two_bundle_direct_instance(5; with_hub=true)
    filt = lower_bound_filtering(instance; show_progress=false)
    @test is_feasible(filt, instance)
    @test count(
        p -> TPO._direct_arc_position(instance.index_cache, p) != 0, filt.bundle_paths
    ) == 1
    @test count(
        p -> TPO._direct_arc_position(instance.index_cache, p) == 0, filt.bundle_paths
    ) == 1

    res = TransportationPlanningOptimization.solve_filtered(instance; show_progress=false)
    @test length(res.sub_instance.bundles) == 1
    merged = TransportationPlanningOptimization.merge_solutions(
        filt, res.solution_state, instance, res.sub_instance
    )
    @test is_feasible(merged, instance)
    @test cost(merged) == 9.0
end

@testset "lower_bound_filtering fixes every bundle on a roomy direct arc" begin
    instance = two_bundle_direct_instance(1000; with_hub=true)
    filt = lower_bound_filtering(instance; show_progress=false)
    @test all(
        p -> TPO._direct_arc_position(instance.index_cache, p) != 0, filt.bundle_paths
    )
    @test is_feasible(filt, instance)
end

@testset "lower_bound_filtering throws when fixed bundles leave no feasible path" begin
    instance = two_bundle_direct_instance(5; with_hub=false)
    @test_throws "No feasible filtering path" lower_bound_filtering(
        instance; show_progress=false
    )
    @test_throws "previously fixed" lower_bound_filtering(instance; show_progress=false)
    # Nothing is fixed when even the first bundle does not fit: no hint.
    too_small = two_bundle_direct_instance(2; with_hub=false)
    err = try
        lower_bound_filtering(too_small; show_progress=false)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("No feasible filtering path", err.msg)
    @test !occursin("previously fixed", err.msg)
end

@testset "lower_bound_filtering fixes one bundle per mode of parallel legs" begin
    # Two A->B legs of capacity 5 with the same transit time form a MultiModalArc:
    # each size-3 bundle fits one leg only, so both are fixed, one per mode.
    nodes = [Node(; id="A"), Node(; id="B")]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=5,
        ) for _ in 1:2
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=3.0,
            info="p$k",
        ) for k in 1:2
    ]
    instance = Instance(
        nodes, arcs, commodities, Day(1); group_by=c -> c.info, allow_multimodal=true
    )
    filt = lower_bound_filtering(instance; show_progress=false)
    @test all(
        p -> TPO._direct_arc_position(instance.index_cache, p) != 0, filt.bundle_paths
    )
    @test is_feasible(filt, instance)
end

@testset "lower_bound_filtering fixes the direct-only bundle first and routes the other" begin
    # Y (size 3, direct only) is processed before X (size 2.5, hub possible):
    # Y takes the direct arc, so X no longer fits it and is kept, routed via the hub.
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="H")]
    arcs = [
        Arc(;
            origin_id=o,
            destination_id=d,
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=cap,
        ) for (o, d, cap) in (("A", "B", 5), ("A", "H", 100), ("H", "B", 100))
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(mdt),
            size=size,
            info=info,
        ) for (info, size, mdt) in (("X", 2.5, 2), ("Y", 3.0, 1))
    ]
    instance = Instance(nodes, arcs, commodities, Day(1); group_by=c -> c.info)
    filt = lower_bound_filtering(instance; show_progress=false)
    @test is_feasible(filt, instance)
    @test sort(length.(filt.bundle_paths)) == [2, 3]

    res = TransportationPlanningOptimization.solve_filtered(instance; show_progress=false)
    @test length(res.sub_instance.bundles) == 1
    merged = TransportationPlanningOptimization.merge_solutions(
        filt, res.solution_state, instance, res.sub_instance
    )
    @test is_feasible(merged, instance)
end

@testset "lower_bound and lower_bound_filtering skip a batch that overflows a bin-packed arc" begin
    # Bundle A->D has two candidate routes: the cheap A->B->D detour, whose
    # B->D leg has a capacity (and bin capacity) smaller than the single
    # commodity's size, and the pricier but feasible A->C->D route. B->D is
    # not the bundle's direct origin/destination arc, so pricing it goes
    # through `_edge_lower_bound_cost`, which must return `Inf` for the
    # overflowing batch instead of letting Dijkstra route the bundle onto it:
    # FFD bin packing would otherwise throw `DomainError` when the cheaper
    # path is committed.
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C"), Node(; id="D")]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="B",
            destination_id="D",
            cost=(LinearArcCost(1.0), BinPackingArcCost(10.0, 4)),
            travel_time=Day(1),
            capacity=4,
        ),
        Arc(;
            origin_id="A",
            destination_id="C",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=10,
        ),
        Arc(;
            origin_id="C",
            destination_id="D",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=10,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="D",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(3),
            size=7.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))

    lb_sol = lower_bound(instance; show_progress=false)
    @test is_feasible(lb_sol, instance)
    @test length(only(lb_sol.bundle_paths)) == 3

    filt_sol = lower_bound_filtering(instance; show_progress=false)
    @test is_feasible(filt_sol, instance)
    @test length(only(filt_sol.bundle_paths)) == 3
end

@testset "lower_bound and lower_bound_filtering skip a batch that overflows the direct arc" begin
    # Bundle A->B's own direct arc is cheap but its capacity (and bin
    # capacity) is smaller than the single commodity's size. `lower_bound`
    # prices the direct arc through `_direct_arc_lb_cost` /
    # `_direct_arc_order_lb_cost`, which must also gate on the batch alone
    # fitting the arc, or Dijkstra would pick the direct arc and FFD bin
    # packing would throw `DomainError` when the path is committed.
    # `lower_bound_filtering` prices the direct arc through the already gated
    # `compute_ttg_edge_incremental_cost`, so its assertions here are a
    # regression guard rather than a reproduction of the bug. A->C->B is
    # pricier but has enough capacity, so it is the only feasible route.
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C")]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=(LinearArcCost(1.0), BinPackingArcCost(10.0, 4)),
            travel_time=Day(1),
            capacity=4,
        ),
        Arc(;
            origin_id="A",
            destination_id="C",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=10,
        ),
        Arc(;
            origin_id="C",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=10,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=7.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))

    lb_sol = lower_bound(instance; show_progress=false)
    @test is_feasible(lb_sol, instance)
    @test length(only(lb_sol.bundle_paths)) == 3

    filt_sol = lower_bound_filtering(instance; show_progress=false)
    @test is_feasible(filt_sol, instance)
    @test length(only(filt_sol.bundle_paths)) == 3
end

@testset "_edge_lower_bound_cost and _direct_arc_order_lb_cost gate MultiModalArc per mode" begin
    # Two-mode arc: a cheap mode too small for the batch and a pricier mode
    # large enough. Both helpers must skip the too-small mode instead of
    # picking its (invalid) relaxed cost, and return `Inf` when neither mode
    # fits.
    cheap_small = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(1.0), capacity=4)
    pricier_large = NetworkArc(; travel_time_steps=1, cost=LinearArcCost(5.0), capacity=10)
    arc = MultiModalArc([cheap_small, pricier_large])
    comms = [LightCommodity(; origin_id="A", destination_id="B", size=7.0, info=nothing)]
    order = Order(; commodities=comms, time_step=1, max_transit_steps=1)
    expected = 5.0 * order.total_size

    @test TransportationPlanningOptimization._edge_lower_bound_cost(
        arc, nothing, order, CheapestMode()
    ) == expected
    @test TransportationPlanningOptimization._direct_arc_order_lb_cost(
        arc, order, CheapestMode()
    ) == expected

    too_small_both = MultiModalArc([
        NetworkArc(; travel_time_steps=1, cost=LinearArcCost(1.0), capacity=4),
        NetworkArc(; travel_time_steps=1, cost=LinearArcCost(5.0), capacity=4),
    ])
    @test TransportationPlanningOptimization._edge_lower_bound_cost(
        too_small_both, nothing, order, CheapestMode()
    ) == Inf
    @test TransportationPlanningOptimization._direct_arc_order_lb_cost(
        too_small_both, order, CheapestMode()
    ) == Inf
end

# Cost with no commodity bound (default hook returns `nothing`).
struct _NonAdditiveArcCost <: TransportationPlanningOptimization.AbstractArcCostFunction end
function TransportationPlanningOptimization.evaluate(
    ::_NonAdditiveArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    return 2.0 * sqrt(sum(c.size for c in comms; init=0.0))
end

function _fts_comm(size, stock=0.0)
    return LightCommodity(;
        origin_id="A",
        destination_id="B",
        size=Float64(size),
        info=InboundCommodityInfo(stock),
    )
end
_fts_order(comms) = Order(; commodities=comms, time_step=1, max_transit_steps=1)
_fts_hook(f, c) = TransportationPlanningOptimization.lower_bound_commodity_cost(f, c)
_fts_mode(cost, cap) = NetworkArc(; travel_time_steps=1, cost, capacity=cap)

@testset "FillThenSpillMode lower bound hand cases" begin
    TPO = TransportationPlanningOptimization
    lb(arc, order) = TPO._edge_lower_bound_cost(arc, nothing, order, FillThenSpillMode())

    # StockArcCost: the per-commodity bound is exact, unlike the min of whole-order bounds.
    m1 = _fts_mode(TPO.SumArcCost((LinearArcCost(1.0), StockArcCost(1.0))), 10)
    m2 = _fts_mode(TPO.SumArcCost((LinearArcCost(20.0), StockArcCost(0.0))), 100)
    arc = MultiModalArc([m1, m2])
    comms = [_fts_comm(10.0, 0.0), _fts_comm(1.0, 100.0)]
    order = _fts_order(comms)
    true_cost = TPO._edge_incremental_cost(arc, nothing, comms, FillThenSpillMode())
    @test true_cost ≈ 30.0
    @test lb(arc, order) ≈ 30.0
    @test lb(arc, order) <= true_cost + 1e-9

    # Fractional bins: a direct-arc ceil would give 2.0 above the true cost of 1.5.
    b1 = _fts_mode(BinPackingArcCost(1.0, 10), 10)
    b2 = _fts_mode(BinPackingArcCost(0.5, 1), 100)
    bp_arc = MultiModalArc([b1, b2])
    bp_comms = [_fts_comm(1.0) for _ in 1:11]
    bp_order = _fts_order(bp_comms)
    @test TPO._edge_incremental_cost(bp_arc, nothing, bp_comms, FillThenSpillMode()) ≈ 1.5
    direct = TPO._direct_arc_order_lb_cost(bp_arc, bp_order, FillThenSpillMode())
    @test direct ≈ 1.1
    @test direct <= 1.5

    # Infeasible gates.
    small = MultiModalArc([
        _fts_mode(LinearArcCost(1.0), 3), _fts_mode(LinearArcCost(2.0), 4)
    ])
    @test lb(small, _fts_order([_fts_comm(4.0), _fts_comm(4.0)])) == Inf
    @test lb(small, _fts_order([_fts_comm(2.0), _fts_comm(2.0), _fts_comm(2.0)])) ≈ 6.0
    @test lb(small, _fts_order([_fts_comm(5.0)])) == Inf

    # Unbounded capacity disables the gates.
    unbounded = MultiModalArc([
        _fts_mode(LinearArcCost(1.0), typemax(Int)), _fts_mode(LinearArcCost(2.0), 1)
    ])
    @test lb(unbounded, _fts_order([_fts_comm(1000.0)])) ≈ 1000.0

    # Heterogeneous modes (bin packing and linear).
    het = MultiModalArc([
        _fts_mode(BinPackingArcCost(4.0, 2), 6), _fts_mode(LinearArcCost(1.5), 6)
    ])
    het_comms = [_fts_comm(1.0), _fts_comm(2.0), _fts_comm(3.0)]
    @test lb(het, _fts_order(het_comms)) ≈ 9.0

    # A mode without commodity bound contributes 0 for the commodities it can carry.
    non_additive = MultiModalArc([
        _fts_mode(LinearArcCost(1.0), 10), _fts_mode(_NonAdditiveArcCost(), 10)
    ])
    @test lb(non_additive, _fts_order([_fts_comm(2.0)])) == 0.0
    @test lb(non_additive, _fts_order([_fts_comm(20.0)])) == Inf

    # A hookless term of a SumArcCost contributes 0, the other terms still count.
    summed = TPO.SumArcCost((LinearArcCost(2.0), _NonAdditiveArcCost()))
    hooked_comm = _fts_comm(3.0)
    @test _fts_hook(summed, hooked_comm) == 6.0
    @test (@allocated _fts_hook(summed, hooked_comm)) == 0

    # c1 fits only the hooked mode A, c2 fits A and the hookless mode B: 5 + 0.
    mixed = MultiModalArc([
        _fts_mode(LinearArcCost(2.5), 10), _fts_mode(_NonAdditiveArcCost(), 1)
    ])
    @test lb(mixed, _fts_order([_fts_comm(2.0), _fts_comm(1.0)])) ≈ 5.0

    # One EPS of slack per mode on the total capacity, as the partition allows.
    tight = MultiModalArc([
        _fts_mode(LinearArcCost(1.0), 1), _fts_mode(LinearArcCost(2.0), 1)
    ])
    tight_comms = [_fts_comm(1 + 0.9e-8), _fts_comm(1 + 0.9e-8)]
    tight_lb = lb(tight, _fts_order(tight_comms))
    @test isfinite(tight_lb)
    @test tight_lb <=
        TPO._edge_incremental_cost(tight, nothing, tight_comms, FillThenSpillMode())
    @test TPO._edge_incremental_cost(tight, nothing, tight_comms, FillThenSpillMode()) ≈ 3.0
end

@testset "FillThenSpillMode lower bound never exceeds any split" begin
    TPO = TransportationPlanningOptimization
    rng = MersenneTwister(2024)
    random_cost() =
        rand(rng, 1:4) |>
        k -> if k == 1
            LinearArcCost(rand(rng) * 3)
        elseif k == 2
            BinPackingArcCost(1 + rand(rng) * 5, rand(rng, 4:8))
        elseif k == 3
            TPO.SumArcCost((LinearArcCost(rand(rng) * 2), StockArcCost(rand(rng) * 2)))
        else
            TPO.SumArcCost((
                BinPackingArcCost(1 + rand(rng) * 5, rand(rng, 4:8)),
                LinearArcCost(rand(rng) * 2),
                StockArcCost(rand(rng) * 2),
            ))
        end
    for _ in 1:300
        n_modes = rand(rng, 2:3)
        arc = MultiModalArc([_fts_mode(random_cost(), rand(rng, 2:10)) for _ in 1:n_modes])
        comms = [
            _fts_comm(rand(rng, 1:4), round(rand(rng) * 5; digits=1)) for
            _ in 1:rand(rng, 1:5)
        ]
        order = _fts_order(comms)
        bound = TPO._edge_lower_bound_cost(arc, nothing, order, FillThenSpillMode())

        best = Inf
        for assign in Iterators.product(ntuple(_ -> 1:n_modes, length(comms))...)
            parts = [comms[findall(==(m), collect(assign))] for m in 1:n_modes]
            all(
                sum(c.size for c in parts[m]; init=0.0) <= arc.modes[m].capacity + 1e-8 for
                m in 1:n_modes
            ) || continue
            best = min(
                best,
                sum(
                    TPO.evaluate(arc.modes[m].cost, parts[m]) for
                    m in 1:n_modes if !isempty(parts[m])
                ),
            )
        end
        @test bound <= best + 1e-9
        isinf(bound) && @test isinf(best)
        fts = TPO._edge_incremental_cost(arc, nothing, comms, FillThenSpillMode())
        isfinite(fts) && @test bound <= fts + 1e-9
    end
end

@testset "FillThenSpillMode lower bounds sum below the final arc cost" begin
    TPO = TransportationPlanningOptimization
    rng = MersenneTwister(7)
    C = LightCommodity{InboundCommodityInfo}
    for _ in 1:100
        arc = MultiModalArc([
            _fts_mode(BinPackingArcCost(3.0, 4), 20),
            _fts_mode(TPO.SumArcCost((LinearArcCost(1.0), StockArcCost(0.5))), 20),
        ])
        assignments = Dict{Tuple{Int,Int},TPO.AbstractArcAssignment{C}}()
        total = 0.0
        for _ in 1:rand(rng, 1:4)
            comms = [
                _fts_comm(rand(rng, 1:3), round(rand(rng) * 4; digits=1)) for
                _ in 1:rand(rng, 1:3)
            ]
            order = _fts_order(comms)
            existing = get(assignments, (1, 2), nothing)
            total += TPO._edge_lower_bound_cost(arc, existing, order, FillThenSpillMode())
            TPO._add_order_to_assignment!(
                assignments, (1, 2), arc, comms, FillThenSpillMode(), [NoNodeCost()], 1
            )
        end
        final = sum(slot.arc_cost for slot in assignments[(1, 2)].per_mode)
        @test total <= final + 1e-9
    end
end

function _fts_lb_empty(a, o, s)
    return TransportationPlanningOptimization._edge_lower_bound_cost(a, nothing, o, s)
end
function _fts_lb_loaded(a, e, o, s)
    return TransportationPlanningOptimization._edge_lower_bound_cost(a, e, o, s)
end
function _fts_lb_direct(a, o, s)
    return TransportationPlanningOptimization._direct_arc_order_lb_cost(a, o, s)
end

@testset "FillThenSpillMode lower bound is allocation-free" begin
    TPO = TransportationPlanningOptimization
    C = LightCommodity{InboundCommodityInfo}
    arc = MultiModalArc([
        _fts_mode(BinPackingArcCost(3.0, 4), 20),
        _fts_mode(TPO.SumArcCost((LinearArcCost(1.0), StockArcCost(0.5))), 20),
    ])
    comms = [_fts_comm(2.0, 1.0), _fts_comm(3.0, 2.0)]
    order = _fts_order(comms)
    assignments = Dict{Tuple{Int,Int},TPO.AbstractArcAssignment{C}}()
    TPO._add_order_to_assignment!(
        assignments, (1, 2), arc, comms, FillThenSpillMode(), [NoNodeCost()], 1
    )
    loaded = assignments[(1, 2)]
    sel = FillThenSpillMode()
    _fts_lb_empty(arc, order, sel)
    _fts_lb_loaded(arc, loaded, order, sel)
    _fts_lb_direct(arc, order, sel)
    @test (@allocated _fts_lb_empty(arc, order, sel)) == 0
    @test (@allocated _fts_lb_loaded(arc, loaded, order, sel)) == 0
    @test (@allocated _fts_lb_direct(arc, order, sel)) == 0
end

@testset "lower_bound with FillThenSpillMode on a multi-modal instance" begin
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="D")]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=2,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(20.0),
            travel_time=Day(1),
            capacity=100,
        ),
        Arc(;
            origin_id="B", destination_id="D", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="D", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
    ]
    commodity = Commodity(;
        origin_id="A",
        destination_id="D",
        quantity=4,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(3),
        size=1.0,
    )
    instance = Instance(nodes, arcs, [commodity], Day(1); allow_multimodal=true)
    for f in (lower_bound, lower_bound_filtering)
        sol = f(instance, FillThenSpillMode(); show_progress=false)
        @test length(only(sol.bundle_paths)) == 3
        direct = f(instance; show_progress=false)
        @test length(only(direct.bundle_paths)) == 2
    end
end

@testset "_no_path_error reports the bundle, its constraints and the causes" begin
    nodes = [Node(; id=id) for id in ("A", "B", "X", "C")]
    arcs = [
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(1))
        for (o, d) in (("A", "B"), ("A", "X"), ("X", "B"), ("A", "C"), ("C", "B"))
    ]
    commodity = Commodity(;
        origin_id="A",
        destination_id="B",
        quantity=1,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(2),
        size=1.0,
        forbidden_node_ids=["X"],
        forbidden_arcs=[("A", "C")],
    )
    instance = Instance(nodes, arcs, [commodity], Day(1))

    err = TPO._no_path_error(instance, 1, "lower-bound")
    @test err isa ArgumentError
    msg = err.msg
    @test occursin("No feasible lower-bound path for bundle 1", msg)
    @test occursin("A -> B", msg)
    @test occursin("max_transit_steps=2", msg)
    @test occursin("forbidden_nodes=Set([\"X\"])", msg)
    @test occursin("forbidden_arcs=Set([(\"A\", \"C\")])", msg)
    @test occursin("time budget", msg)
    @test occursin("capacities", msg)
    @test !occursin("previously fixed", msg)
    hinted = TPO._no_path_error(instance, 1, "filtering"; fixed_hint=true)
    @test occursin("previously fixed", hinted.msg)
end

@testset "lower bounds on tight multi-modal capacities do not throw" begin
    # The relaxed pricing ignores the load, so the lower bound may overload the modes.
    arm2 = TestFixtures.lb_arm2_instance()
    for (selector, expected) in ((CheapestMode(), 32.0), (FillThenSpillMode(), 24.0))
        lb_sol = lower_bound(arm2, selector; show_progress=false)
        @test TPO.cost(lb_sol) == expected
        @test !TPO.is_feasible(lb_sol, arm2)
        @test TPO.lower_bound_filtering(arm2, selector; show_progress=false) isa
            TPO.SolutionState
    end

    fragmented = TestFixtures.fragmented_modes_instance()
    for selector in (CheapestMode(), FillThenSpillMode())
        @test lower_bound(fragmented, selector; show_progress=false) isa TPO.SolutionState
        @test TPO.lower_bound_filtering(fragmented, selector; show_progress=false) isa
            TPO.SolutionState
    end
end
