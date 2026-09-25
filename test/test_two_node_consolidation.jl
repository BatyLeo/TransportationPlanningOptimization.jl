using Test
using TransportationPlanningOptimization
using Dates
using Graphs
using MetaGraphsNext: label_for, code_for
using Random: MersenneTwister

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "bundles_through_arc returns matching bundles" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()

    first_with_arc = findfirst(p -> length(p) >= 2, sol.bundle_paths)
    @assert first_with_arc !== nothing "no bundle has a length-2+ path on small"
    path = sol.bundle_paths[first_with_arc]
    src, dst = path[1], path[2]

    matched = TPO.bundles_through_arc(sol, src, dst)
    @test first_with_arc in matched
    expected = Int[]
    for i in 1:bundle_count(instance)
        p = sol.bundle_paths[i]
        if any(k -> p[k] == src && p[k + 1] == dst, 1:(length(p) - 1))
            push!(expected, i)
        end
    end
    @test matched == expected

    @test isempty(TPO.bundles_through_arc(sol, src, src))
end

@testset "merge_bundles unions orders + forbidden, picks max-transit donor" begin
    instance = TestFixtures.small_instance()

    lifted_idxs = [1, 2]
    virtual, virtual_arcs = TPO.merge_bundles(instance, lifted_idxs)

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

    @test virtual_arcs === instance.travel_time_graph.bundle_arcs[lifted_idxs[donor_local]]

    @test_throws ArgumentError TPO.merge_bundles(instance, Int[])
end

@testset "merge_bundles merges orders sharing a time step" begin
    instance = TestFixtures.small_instance()
    lifted_idxs = [1, 2]
    virtual, _ = TPO.merge_bundles(instance, lifted_idxs)

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

@testset "splice_path replaces (src, dst) sub-segment" begin
    @test TPO.splice_path([1, 2, 3, 4], 2, 3, [2, 99, 100, 3]) == [1, 2, 99, 100, 3, 4]
    @test TPO.splice_path([1, 2, 3], 2, 3, [2, 3]) == [1, 2, 3]
    @test TPO.splice_path([2, 3, 4], 2, 3, [2, 99, 3]) == [2, 99, 3, 4]
    @test TPO.splice_path([1, 2, 3], 2, 3, [2, 99, 3]) == [1, 2, 99, 3]

    @test_throws ArgumentError TPO.splice_path([1, 2, 3], 5, 6, [5, 6])
    @test_throws ArgumentError TPO.splice_path([1, 2, 3], 2, 3, [2, 99, 4])
    @test_throws ArgumentError TPO.splice_path([1, 2, 3], 2, 3, [99, 2, 3])
    @test_throws ArgumentError TPO.splice_path([1, 2, 3], 2, 3, Int[])
end

@testset "compute_candidate_nodes filters by node_type" begin
    instance = TestFixtures.small_instance()
    valid_pairs = TPO.compute_candidate_nodes(instance.travel_time_graph)

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
        if length(TPO.bundles_through_arc(sol, s, d)) >= 2
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
        if length(TPO.bundles_through_arc(sol, s, d)) >= 2
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
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="H", node_type=:other),
        NetworkNode(; id="Z", node_type=:other),
        NetworkNode(; id="C", node_type=:other),
        NetworkNode(; id="B", node_type=:destination),
        NetworkNode(; id="D", node_type=:destination),
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
    sol = Solution(bundle_paths, instance)
    @test is_feasible(sol, instance; verbose=true)

    src, dst = code("H"), code("C")
    @test TPO.bundles_through_arc(sol, src, dst) == sort([idx_b, idx_d])

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
