using Test
using TransportationPlanningOptimization
using Dates
using Graphs
using SparseArrays: SparseArrays
using MetaGraphsNext: label_for, code_for
using Random: MersenneTwister
using TransportationPlanningOptimization.Problems.Inbound: parse_inbound_instance

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures
using .TestFixtures: same_state, edge_multisets

# Indices of the bundles visiting `src` then `dst`.
through_idxs(sol, src, dst) = [i for (i, _, _) in TPO.bundles_through_nodes(sol, src, dst)]

@testset "merge_bundles unions orders + forbidden, picks max-transit donor" begin
    instance = TestFixtures.small_instance()

    lifted_idxs = [1, 2]
    virtual = TPO.merge_bundles(instance, lifted_idxs)

    all_lifted_orders = vcat(instance.bundles[1].orders, instance.bundles[2].orders)
    expected_order_count = length(Set(o.time_step for o in all_lifted_orders))
    @test length(virtual.orders) == expected_order_count
    @test allunique(o.time_step for o in virtual.orders)

    expected_forbidden_nodes = union(
        instance.bundles[1].forbidden_nodes, instance.bundles[2].forbidden_nodes
    )
    @test virtual.forbidden_nodes == expected_forbidden_nodes

    expected_forbidden_arcs = union(
        instance.bundles[1].forbidden_arcs, instance.bundles[2].forbidden_arcs
    )
    @test virtual.forbidden_arcs == expected_forbidden_arcs

    max1 = maximum(o.max_transit_steps for o in instance.bundles[1].orders)
    max2 = maximum(o.max_transit_steps for o in instance.bundles[2].orders)
    donor_local = max1 >= max2 ? 1 : 2
    @test virtual.origin_id == instance.bundles[lifted_idxs[donor_local]].origin_id
    @test virtual.destination_id ==
        instance.bundles[lifted_idxs[donor_local]].destination_id

    @test TPO._donor_index(instance, lifted_idxs) == lifted_idxs[donor_local]

    @test_throws ArgumentError TPO.merge_bundles(instance, Int[])
end

@testset "merge_bundles merges orders sharing a time step" begin
    instance = TestFixtures.small_instance()
    lifted_idxs = [1, 2]
    virtual = TPO.merge_bundles(instance, lifted_idxs)

    all_orders_flat = vcat(instance.bundles[1].orders, instance.bundles[2].orders)
    distinct_steps = Set(o.time_step for o in all_orders_flat)
    @test length(distinct_steps) < length(all_orders_flat)
    @test issorted(o.time_step for o in virtual.orders)

    # Total size and total commodity count are preserved across the merge.
    @test sum(total_size(o) for o in virtual.orders) ≈
        sum(total_size(o) for o in all_orders_flat)
    @test sum(length(o.commodities) for o in virtual.orders) ==
        sum(length(o.commodities) for o in all_orders_flat)

    # The merged order at the colliding time step keeps the tighter transit budget.
    collision_step = first(
        t for t in distinct_steps if count(o -> o.time_step == t, all_orders_flat) > 1
    )
    merged_order = only(filter(o -> o.time_step == collision_step, virtual.orders))
    sources = filter(o -> o.time_step == collision_step, all_orders_flat)
    @test merged_order.max_transit_steps == minimum(o.max_transit_steps for o in sources)
end

@testset "splice_path replaces the lo:hi sub-segment" begin
    instance = TestFixtures.small_instance()
    ttg = instance.travel_time_graph
    sol = TestFixtures.small_greedy()
    path = copy(sol.bundle_paths[findfirst(p -> length(p) >= 5, sol.bundle_paths)])
    # Two node codes absent from the path, used as detour nodes of the spliced sub-paths.
    x, y = setdiff(1:Graphs.nv(ttg.graph), path)[1:2]
    a, b, c, d, e = path[1:5]

    @test TPO.splice_path(path, 2, 3, [b, x, y, c], ttg) ==
        (vcat(path[1:2], [x, y], path[3:end]), 5)
    @test TPO.splice_path(path, 2, 3, [b, c], ttg) == (path, 3)
    @test TPO.splice_path(path, 2, 4, [b, x, d], ttg) ==
        (vcat(path[1:2], [x], path[4:end]), 4)
    @test TPO.splice_path(path[1:3], 1, 2, [a, x, b], ttg) == (vcat([a, x], path[2:3]), 3)
    new, _ = TPO.splice_path(path, 2, 3, [b, c], ttg)
    @test new !== path

    @test_throws ArgumentError TPO.splice_path(path, 99, 100, [a, b], ttg)
    @test_throws ArgumentError TPO.splice_path(path, 3, 2, [c, b], ttg)
    @test_throws ArgumentError TPO.splice_path(path, 2, 3, [b, x, d], ttg)
    @test_throws ArgumentError TPO.splice_path(path, 2, 3, [x, b, c], ttg)
    @test_throws ArgumentError TPO.splice_path(path, 2, 3, Int[], ttg)
end

@testset "splice_path strips the shortcut nodes of the new sub-path only" begin
    # Arrival mode: the origin node of the TTG is followed by a shortcut to the first
    # timed node, which a splice at lo == 1 removes and the suffix keeps its length.
    nodes = [
        Node(; id="O", node_type=:origin),
        Node(; id="H", node_type=:other),
        Node(; id="D", node_type=:destination),
    ]
    arc(o, d) =
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(1))
    commodity = Commodity(;
        origin_id="O",
        destination_id="D",
        quantity=1,
        arrival_date=DateTime(2021, 1, 5),
        max_delivery_time=Day(3),
        size=1.0,
    )
    instance = Instance(nodes, [arc("O", "H"), arc("H", "D")], [commodity], Day(1))
    ttg = instance.travel_time_graph
    clean = copy(greedy_heuristic(instance; show_progress=false).bundle_paths[1])
    old = vcat(ttg.origin_codes[1], clean)
    @test old[1] != clean[1]
    path, new_hi = TPO.splice_path(old, 1, 2, old[1:2], ttg)
    @test path == clean
    @test new_hi == 1
    @test length(path) - new_hi == length(old) - 2
    # Stored paths are already clean, so splicing one back strips nothing.
    @test TPO.splice_path(clean, 1, 2, clean[1:2], ttg) == (clean, 2)
end

@testset "compute_candidate_nodes filters by node_type" begin
    instance = TestFixtures.small_instance()
    valid_pairs = TPO.compute_candidate_nodes(instance)

    g = instance.travel_time_graph.graph
    @test !isempty(valid_pairs)
    for (s, d) in valid_pairs
        @test g[label_for(g, s)].node_type == :other
        @test g[label_for(g, d)].node_type in (:other, :destination)
        @test s != d
        @test Graphs.has_edge(g, s, d)
    end
end

@testset "TPO.two_node_common_incremental! feasibility on small" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    cost_before = cost(sol)

    # Find a (src, dst) arc with at least 2 bundles passing through it.
    matched_src, matched_dst = 0, 0
    for (i, path) in enumerate(sol.bundle_paths), k in 1:(length(path) - 1)
        s, d = path[k], path[k + 1]
        if length(TPO.bundles_through_nodes(sol, s, d)) >= 2
            matched_src, matched_dst = s, d
            break
        end
    end
    @assert matched_src != 0 "no arc with >= 2 bundles found on small greedy solution"

    saved = TPO.two_node_common_incremental!(sol, instance, matched_src, matched_dst)
    @test is_feasible(sol, instance; verbose=true)
    @test saved >= -1e-6
    @test isapprox(cost_before - cost(sol), saved; atol=1e-6)
end

@testset "TPO.two_node_common_incremental! with refine stays feasible" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    cost_before = cost(sol)

    matched_src, matched_dst = 0, 0
    for (i, path) in enumerate(sol.bundle_paths), k in 1:(length(path) - 1)
        s, d = path[k], path[k + 1]
        if length(TPO.bundles_through_nodes(sol, s, d)) >= 2
            matched_src, matched_dst = s, d
            break
        end
    end
    @assert matched_src != 0

    saved = TPO.two_node_common_incremental!(
        sol, instance, matched_src, matched_dst; refine=true
    )
    @test is_feasible(sol, instance; verbose=true)
    @test saved >= -1e-6
    @test cost(sol) <= cost_before + 1e-6
end

@testset "TPO.two_node_common_incremental! respects capacity with same-time-step orders" begin
    # Regression for the merge_bundles capacity bug: bundles B and D deliver on
    # the same date and both start on the direct, uncapacitated H->C arc. A
    # cheaper detour H->Z->C has capacity 2, below their combined size (3.0)
    # but above either order alone (1.5), so pre-fix pricing (one order at a
    # time) wrongly accepts the detour and overflows H->Z.
    nodes = [
        Node(; id="A", node_type=:origin),
        Node(; id="H", node_type=:other),
        Node(; id="Z", node_type=:other),
        Node(; id="C", node_type=:other),
        Node(; id="B", node_type=:destination),
        Node(; id="D", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="H", cost=LinearArcCost(0.0), travel_time=Day(0)
        ),
        Arc(;
            origin_id="H",
            destination_id="Z",
            cost=LinearArcCost(0.5),
            travel_time=Day(0),
            capacity=2,
        ),
        Arc(;
            origin_id="Z", destination_id="C", cost=LinearArcCost(0.5), travel_time=Day(0)
        ),
        Arc(;
            origin_id="H", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(0)
        ),
        Arc(;
            origin_id="C", destination_id="B", cost=LinearArcCost(0.0), travel_time=Day(0)
        ),
        Arc(;
            origin_id="C", destination_id="D", cost=LinearArcCost(0.0), travel_time=Day(0)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(0),
            size=1.5,
        ),
        Commodity(;
            origin_id="A",
            destination_id="D",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(0),
            size=1.5,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    ttg = instance.travel_time_graph
    idx_b = findfirst(b -> b.destination_id == "B", instance.bundles)
    idx_d = findfirst(b -> b.destination_id == "D", instance.bundles)

    # Build both bundles directly on the direct A->H->C->{B,D} route.
    code(id) = code_for(ttg.graph, (id, 0))
    bundle_paths = Vector{Vector{Int}}(undef, 2)
    bundle_paths[idx_b] = [code("A"), code("H"), code("C"), code("B")]
    bundle_paths[idx_d] = [code("A"), code("H"), code("C"), code("D")]
    sol = SolutionState(bundle_paths, instance)
    @test is_feasible(sol, instance; verbose=true)

    src, dst = code("H"), code("C")
    @test through_idxs(sol, src, dst) == sort([idx_b, idx_d])

    old_paths = deepcopy(sol.bundle_paths)
    saved = TPO.two_node_common_incremental!(sol, instance, src, dst; refine=false)
    @test saved == 0.0
    @test sol.bundle_paths == old_paths
    @test is_feasible(sol, instance; verbose=true)
end

@testset "TPO.loop_two_nodes! smoke test on small" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    c0 = cost(sol)

    rng = MersenneTwister(20260524)
    saved = TPO.loop_two_nodes!(sol, instance; time_limit=3.0, refine=false, rng=rng)

    @test is_feasible(sol, instance; verbose=true)
    @test saved >= -1e-6
    @test cost(sol) <= c0 + 1e-6
end

@testset "merge_bundles recomputes the order aggregate of merged orders" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        (joinpath(datadir, "small_$(f).csv") for f in ("nodes", "legs", "commodities"))...
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    virtual = TPO.merge_bundles(instance, [1, 2])
    @test length(virtual.orders) < sum(length(instance.bundles[i].orders) for i in (1, 2))
    for o in virtual.orders
        @test o.aggregate.stock_cost ===
            sum(x.info.stock_cost for x in o.commodities; init=0.0)
    end
end

# First arc of the solution traversed by at least two bundles.
function shared_arc(sol)
    for path in sol.bundle_paths, k in 1:(length(path) - 1)
        s, d = path[k], path[k + 1]
        length(TPO.bundles_through_nodes(sol, s, d)) >= 2 && return s, d
    end
    return error("no arc with >= 2 bundles")
end

@testset "precomputed empty-arc FFD counts leave the merged cost matrix unchanged" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    src, dst = shared_arc(sol)
    lifted = through_idxs(sol, src, dst)
    foreach(i -> TPO.remove_bundle_path!(sol, instance, i), lifted)
    virtual = TPO.merge_bundles(instance, lifted)
    arcs = instance.travel_time_graph.bundle_arcs[TPO._donor_index(instance, lifted)]
    nz = SparseArrays.nonzeros(instance.travel_time_graph.cost_matrix)

    TPO.update_bundle_cost_matrix!(sol, instance, virtual, arcs, TPO.CheapestMode())
    plain = copy(nz)
    counts = TPO.empty_pack_counts(instance, virtual, arcs)
    @test all(ec -> !isempty(ec.capacities), counts)
    TPO.update_bundle_cost_matrix!(
        sol, instance, virtual, arcs, TPO.CheapestMode(); empty_counts=counts
    )
    @test reinterpret(UInt64, nz) == reinterpret(UInt64, plain)
    @test any(isfinite, plain)
    # Deliberately wrong counts must change the matrix, so they are really used.
    bumped = [TPO.EmptyPackCounts(ec.capacities, ec.counts .+ 1) for ec in counts]
    TPO.update_bundle_cost_matrix!(
        sol, instance, virtual, arcs, TPO.CheapestMode(); empty_counts=bumped
    )
    @test any(i -> isfinite(plain[i]) && nz[i] != plain[i], eachindex(nz))
end

@testset "two_node_common_incremental! with a passed deadline restores the solution" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    before = deepcopy(sol)
    src, dst = shared_arc(sol)
    @test length(TPO.bundles_through_nodes(sol, src, dst)) >= 2
    saved = TPO.two_node_common_incremental!(sol, instance, src, dst; deadline=0.0)
    @test saved == 0.0
    @test sol.bundle_paths == before.bundle_paths
    @test keys(sol.assignments) == keys(before.assignments)
    slots(a::TPO.SingleAssignment) = [a]
    slots(a::TPO.MultiAssignment) = a.per_mode
    for (edge, a) in sol.assignments,
        (s, s0) in zip(slots(a), slots(before.assignments[edge]))

        for f in fieldnames(TPO.SingleAssignment)
            f === :bins && continue
            @test getfield(s, f) == getfield(s0, f)
        end
        @test [(b.commodities, b.remaining_capacity) for b in s.bins] == [(b.commodities, b.remaining_capacity) for b in s0.bins]
    end
    # Every slot's `arc_cost` is compared exactly above. The total is only close because
    # `deepcopy` can change the Dict iteration order, so the sum differs in the last bits.
    @test cost(sol) ≈ cost(before) rtol = 1e-12
end

@testset "cost matrix sweep stops at the deadline" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    arcs = instance.travel_time_graph.bundle_arcs[1]
    @test length(arcs) >= TPO.DEADLINE_CHECK_EVERY
    bundle = instance.bundles[1]
    mode = TPO.CheapestMode()
    pool = TPO.create_buffer_pool()
    for deadline in (0.0, Inf)
        expected = deadline == Inf
        @test TPO.update_bundle_cost_matrix!(sol, instance, bundle, arcs, mode; deadline) ==
            expected
        @test TPO.parallel_update_bundle_cost_matrix!(
            sol, instance, bundle, arcs, mode, pool; deadline
        ) == expected
    end
end

@testset "local_search! with a tiny time limit stops and stays consistent" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    c0 = cost(sol)
    r = local_search!(sol, instance; time_limit=1e-3, rng=MersenneTwister(1))
    @test is_feasible(sol, instance; verbose=true)
    @test isapprox(cost(sol), c0 - r.saved; rtol=1e-9)
end

# Chain O1/O2 -> H1 -> H2 -> H3 -> D1/D2 with a cheap detour H1 -> X -> H3, plus a third
# bundle O3 -> H1 -> H2 -> D3 that shares only H1 -> H2. All arcs take no time, so every
# TTG node of the chain has the same code for the three bundles.
function chain_instance(; arrival::Bool, bin_packing::Bool)
    arc_cost(c) = bin_packing ? BinPackingArcCost(c, 10) : LinearArcCost(c)
    nodes = [
        [Node(; id="O$k", node_type=:origin) for k in 1:3]
        [Node(; id=id, node_type=:other) for id in ("H1", "H2", "H3", "X")]
        [Node(; id="D$k", node_type=:destination) for k in 1:3]
    ]
    legs = [
        ("O1", "H1", 1),
        ("O2", "H1", 1),
        ("O3", "H1", 1),
        ("H1", "H2", 8),
        ("H2", "H3", 8),
        ("H1", "X", 1),
        ("X", "H3", 1),
        ("H3", "D1", 1),
        ("H3", "D2", 1),
        ("H2", "D3", 1),
    ]
    arcs = [
        Arc(; origin_id=o, destination_id=d, cost=arc_cost(c), travel_time=Day(0)) for
        (o, d, c) in legs
    ]
    date_key = arrival ? :arrival_date : :departure_date
    commodities = [
        Commodity(;
            origin_id="O$k",
            destination_id="D$k",
            quantity=1,
            (date_key => DateTime(2021, 1, 1)),
            max_delivery_time=Day(0),
            size=sz,
        ) for (k, sz) in ((1, 1.0), (2, 2.0), (3, 1.0))
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

function chain_solution(instance)
    ttg = instance.travel_time_graph
    code(id) = code_for(ttg.graph, (id, 0))
    routes = Dict(
        "O1" => ["O1", "H1", "H2", "H3", "D1"],
        "O2" => ["O2", "H1", "H2", "H3", "D2"],
        "O3" => ["O3", "H1", "H2", "D3"],
    )
    paths = [map(code, routes[b.origin_id]) for b in instance.bundles]
    return SolutionState(paths, instance), code
end

@testset "two-node move reroutes only the slice of the lifted bundles" begin
    for arrival in (true, false), bin_packing in (false, true)
        instance = chain_instance(; arrival, bin_packing)
        ttg = instance.travel_time_graph
        sol, code = chain_solution(instance)
        @test is_feasible(sol, instance; verbose=true)
        b3 = findfirst(b -> b.origin_id == "O3", instance.bundles)
        lifted = TPO.bundles_through_nodes(sol, code("H1"), code("H3"))
        @test sort([i for (i, _, _) in lifted]) == sort(setdiff(1:3, b3))
        @test all(t -> t[2:3] == (2, 4), lifted)

        before = deepcopy(sol)
        c0 = cost(sol)
        # Linear: 3 units leave both 8 arcs and use two 1 arcs. Bins: the H1 -> H2 bin is
        # kept by the third bundle, so only the 8 of H2 -> H3 is replaced by two bins of 1.
        expected = bin_packing ? 6.0 : 42.0
        saved = TPO.two_node_common_incremental!(
            sol, instance, code("H1"), code("H3"); refine=false
        )
        @test saved ≈ expected
        @test cost(sol) ≈ c0 - expected
        for (i, b) in enumerate(instance.bundles)
            ids = [label_for(ttg.graph, v)[1] for v in sol.bundle_paths[i]]
            if b.origin_id == "O3"
                @test ids == ["O3", "H1", "H2", "D3"]
            else
                @test ids[2:4] == ["H1", "X", "H3"]
            end
        end
        @test sol.bundle_paths[b3] == before.bundle_paths[b3]
        @test is_feasible(sol, instance; verbose=true)

        # Prefix and suffix edges (origin legs, H3 -> D, H2 -> D3) are untouched.
        bundle_of(o) = findfirst(b -> b.origin_id == o, instance.bundles)
        tsg_edge(o, u, v) = map(
            n -> TPO.project_to_time_space_graph(
                code(n), instance.bundles[bundle_of(o)].orders[1], instance
            ),
            (u, v),
        )
        untouched = [
            tsg_edge("O1", "O1", "H1"),
            tsg_edge("O2", "O2", "H1"),
            tsg_edge("O3", "O3", "H1"),
            tsg_edge("O1", "H3", "D1"),
            tsg_edge("O2", "H3", "D2"),
            tsg_edge("O3", "H2", "D3"),
        ]
        for edge in untouched
            a, a0 = sol.assignments[edge], before.assignments[edge]
            @test !isempty(a.commodities)
            @test a.commodities == a0.commodities
            @test a.arc_cost == a0.arc_cost
        end
        @test !isempty(sol.assignments[tsg_edge("O1", "H1", "H2")].commodities)
        @test isempty(sol.assignments[tsg_edge("O1", "H2", "H3")].commodities)

        # Running the same move again changes nothing (Dijkstra returns the current slices).
        after = deepcopy(sol)
        @test TPO.two_node_common_incremental!(
            sol, instance, code("H1"), code("H3"); refine=false
        ) == 0.0
        @test same_state(sol, after)
        rebuilt = SolutionState(sol.bundle_paths, instance)
        @test cost(rebuilt) ≈ cost(sol)
    end
end

@testset "two-node move to a destination reached early commits no shortcut edges" begin
    # H -> D takes 3 days but H -> Y -> D takes 2. In departure mode the destination is then
    # reached early and the shortcut arcs ride on to the old arrival time, which the
    # stored path and the assignments must not contain.
    nodes = [
        Node(; id="O", node_type=:origin),
        Node(; id="H", node_type=:other),
        Node(; id="Y", node_type=:other),
        Node(; id="D", node_type=:destination),
    ]
    arc(o, d, c, days) =
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(c), travel_time=Day(days))
    arcs = [
        arc("O", "H", 1, 0), arc("H", "D", 10, 3), arc("H", "Y", 1, 1), arc("Y", "D", 1, 1)
    ]
    commodity = Commodity(;
        origin_id="O",
        destination_id="D",
        quantity=1,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(4),
        size=1.0,
    )
    instance = Instance(nodes, arcs, [commodity], Day(1))
    ttg = instance.travel_time_graph
    code(id, τ) = code_for(ttg.graph, (id, τ))
    sol = SolutionState([[code("O", 0), code("H", 0), code("D", 3)]], instance)
    @test TPO.bundles_through_nodes(sol, code("H", 0), code("D", 3)) == [(1, 2, 3)]
    c0 = cost(sol)

    saved = TPO.two_node_common_incremental!(
        sol, instance, code("H", 0), code("D", 3); refine=false
    )
    @test saved ≈ 8.0
    @test sol.bundle_paths[1] == [code("O", 0), code("H", 0), code("Y", 1), code("D", 2)]
    rebuilt = SolutionState(sol.bundle_paths, instance)
    live(s) = Set(e for (e, a) in s.assignments if !isempty(a.commodities))
    @test live(sol) == live(rebuilt)
    @test length(live(sol)) == 3
    @test cost(sol) ≈ c0 - 8.0
    @test is_feasible(sol, instance; verbose=true)
end

@testset "corridor cost matrix gives the same Dijkstra path and costs as the donor arcs" begin
    instance = TestFixtures.small_instance()
    base = TestFixtures.small_greedy()
    ttg = instance.travel_time_graph
    pairs = Set{Tuple{Int,Int}}()
    for path in base.bundle_paths, k in 1:(length(path) - 1)
        length(through_idxs(base, path[k], path[k + 1])) >= 2 &&
            push!(pairs, (path[k], path[k + 1]))
    end
    @test !isempty(pairs)
    for (src, dst) in first(sort!(collect(pairs)), 4)
        sol = deepcopy(base)
        lifted = TPO.bundles_through_nodes(sol, src, dst)
        foreach(
            ((i, lo, hi),) -> TPO.remove_bundle_subpath!(sol, instance, i, lo, hi), lifted
        )
        idxs = [i for (i, _, _) in lifted]
        virtual = TPO.merge_bundles(instance, idxs)
        donor_arcs = ttg.bundle_arcs[TPO._donor_index(instance, idxs)]
        corridor = TPO._corridor_arcs(ttg.graph, src, dst)
        @test issubset(Set(corridor), Set(donor_arcs))
        @test (src, dst) in corridor

        TPO.update_bundle_cost_matrix!(
            sol, instance, virtual, donor_arcs, TPO.CheapestMode()
        )
        donor_costs = [ttg.cost_matrix[u, v] for (u, v) in corridor]
        parents, _ = TPO.bundle_dijkstra(ttg.graph, src, ttg.cost_matrix; dst)
        donor_path = TPO.trace_path(parents, src, dst)

        TPO.update_bundle_cost_matrix!(sol, instance, virtual, corridor, TPO.CheapestMode())
        @test [ttg.cost_matrix[u, v] for (u, v) in corridor] == donor_costs
        parents, _ = TPO.bundle_dijkstra(ttg.graph, src, ttg.cost_matrix; dst)
        @test TPO.trace_path(parents, src, dst) == donor_path
    end
end

@testset "bundles_through_nodes matches a brute force on random pairs" begin
    sol = TestFixtures.small_greedy()
    rng = MersenneTwister(5)
    paths = filter(!isempty, sol.bundle_paths)
    for _ in 1:30
        src = rand(rng, rand(rng, paths))
        dst = rand(rng, rand(rng, paths))
        expected = NTuple{3,Int}[
            (i, findfirst(==(src), p), findlast(==(dst), p)) for
            (i, p) in enumerate(sol.bundle_paths) if
            src in p && dst in p && findfirst(==(src), p) < findlast(==(dst), p)
        ]
        @test TPO.bundles_through_nodes(sol, src, dst) == expected
    end
    @test isempty(TPO.bundles_through_nodes(sol, paths[1][1], paths[1][1]))
    i = findfirst(q -> length(q) >= 2, sol.bundle_paths)
    p = sol.bundle_paths[i]
    @test all(!=(i) ∘ first, TPO.bundles_through_nodes(sol, p[end], p[1]))
end

@testset "batched removal on edges shared by several slices matches sequential removal" begin
    for bin_packing in (false, true)
        instance = chain_instance(; arrival=true, bin_packing)
        sol, code = chain_solution(instance)
        lifted = TPO.bundles_through_nodes(sol, code("H1"), code("H3"))
        visits = Dict{Tuple{Int,Int},Int}()
        for (i, lo, hi) in lifted
            path = view(sol.bundle_paths[i], lo:hi)
            TPO._foreach_path_edge(instance, instance.bundles[i], path) do edge, _, _
                visits[edge] = get(visits, edge, 0) + 1
                return 0.0
            end
        end
        @test any(>=(2), values(visits))

        sequential = deepcopy(sol)
        for (i, lo, hi) in lifted
            TPO.remove_bundle_subpath!(sequential, instance, i, lo, hi)
        end
        batched = deepcopy(sol)
        delta = TPO.remove_bundle_subpaths!(batched, instance, lifted)
        @test delta < 0
        @test edge_multisets(batched) == edge_multisets(sequential)
        @test cost(batched) ≈ cost(sol) + delta atol = 1e-9
    end
end
