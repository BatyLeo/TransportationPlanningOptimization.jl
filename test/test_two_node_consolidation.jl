using Test
using TransportationPlanningOptimization
using Dates
using MetaGraphsNext: label_for
using Random: MersenneTwister

const TPO = TransportationPlanningOptimization

@testset "bundles_through_arc returns matching bundles" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)

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
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    lifted_idxs = [1, 2]
    virtual, virtual_arcs = TPO.merge_bundles(instance, lifted_idxs)

    expected_order_count =
        length(instance.bundles[1].orders) + length(instance.bundles[2].orders)
    @test length(virtual.orders) == expected_order_count

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
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    src_codes, dst_codes = TPO.compute_candidate_nodes(instance.travel_time_graph)

    g = instance.travel_time_graph.graph
    @test !isempty(src_codes)
    @test all(g[label_for(g, c)].node_type == :other for c in src_codes)
    @test all(g[label_for(g, c)].node_type in (:other, :destination) for c in dst_codes)
    @test issubset(Set(src_codes), Set(dst_codes))
end

@testset "two_node_common_incremental! feasibility on small" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
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

    saved = two_node_common_incremental!(sol, instance, matched_src, matched_dst)
    @test is_feasible(sol, instance; verbose=true)
    @test saved >= -1e-6
    @test isapprox(cost_before - cost(sol), saved; atol=1e-6)
end

@testset "two_node_common_incremental! with refine stays feasible" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
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

    saved = two_node_common_incremental!(
        sol, instance, matched_src, matched_dst; refine=true
    )
    @test is_feasible(sol, instance; verbose=true)
    @test saved >= -1e-6
    @test cost(sol) <= cost_before + 1e-6
end

@testset "loop_two_nodes! smoke test on small" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    c0 = cost(sol)

    rng = MersenneTwister(20260524)
    saved = loop_two_nodes!(sol, instance; time_limit=10.0, refine=false, rng=rng)

    @test is_feasible(sol, instance; verbose=true)
    @test saved >= -1e-6
    @test cost(sol) <= c0 + 1e-6
end
