using Test
using TransportationPlanningOptimization
using Dates

@testset "extract_filtered_instance shrinks bundle count" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    filt = lower_bound_filtering(instance)
    sub = extract_filtered_instance(instance, filt)

    expected_kept = count(p -> length(p) > 2, filt.bundle_paths)
    @test bundle_count(sub) == expected_kept
    @test bundle_count(sub) <= bundle_count(instance)

    # Every bundle retained in `sub` must correspond to a multi-hop path in the
    # original filtering solution.
    kept_origin_dest = Set((b.origin_id, b.destination_id) for b in sub.bundles)
    for (i, bundle) in enumerate(instance.bundles)
        if (bundle.origin_id, bundle.destination_id) in kept_origin_dest
            @test length(filt.bundle_paths[i]) > 2
        end
    end
end

@testset "extract_filtered_instance preserves graph consistency" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    filt = lower_bound_filtering(instance)
    sub = extract_filtered_instance(instance, filt)

    # The sub-instance shares the same time horizon and step.
    @test sub.time_horizon_length == instance.time_horizon_length
    @test sub.time_step == instance.time_step
    @test sub.time_step_to_date == instance.time_step_to_date

    # The sub-network should contain every spatial node still required by
    # retained bundles (origin and destination at minimum).
    for bundle in sub.bundles
        @test haskey(sub.network_graph.graph, bundle.origin_id)
        @test haskey(sub.network_graph.graph, bundle.destination_id)
    end
end

@testset "extract_filtered_instance with all single-hop bundles emits a warning" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    # Force an empty filtering result by fabricating a solution whose paths are
    # all direct arcs (length 2) or empty.
    direct_paths = [
        Int[
            instance.travel_time_graph.origin_codes[i],
            instance.travel_time_graph.destination_codes[i],
        ] for i in eachindex(instance.bundles)
    ]
    fake_filt = Solution(direct_paths, instance)

    @test_logs (:warn,) match_mode = :any extract_filtered_instance(instance, fake_filt)
    sub = (@test_logs (:warn,) match_mode = :any extract_filtered_instance(
        instance, fake_filt
    ))
    @test bundle_count(sub) == 0
end

@testset "merge_solutions produces a feasible full solution" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    filt = lower_bound_filtering(instance)
    sub = extract_filtered_instance(instance, filt)
    sub_sol = greedy_heuristic(sub)

    merged = merge_solutions(filt, sub_sol, instance, sub)

    @test is_feasible(merged, instance; verbose=true)
end

@testset "filter then greedy then merge cheaper than vanilla greedy on small" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    greedy_cost = cost(greedy_heuristic(instance))

    filt = lower_bound_filtering(instance)
    sub = extract_filtered_instance(instance, filt)
    sub_sol = greedy_heuristic(sub)
    merged = merge_solutions(filt, sub_sol, instance, sub)

    @test is_feasible(merged, instance)
    # The filter-greedy pipeline should not blow up cost relative to vanilla greedy.
    # We tolerate up to 1.5x because filtering is approximate (relaxed LB on shared arcs),
    # but in practice it should usually be comparable or better.
    @test cost(merged) <= 1.5 * greedy_cost
end

@testset "merge_solutions errors on duplicate OD pairs" begin
    # `merge_solutions` keys by `(origin_id, destination_id)` and assumes the
    # default `group_by`. If `Instance(...; group_by=f)` is used such that two
    # bundles share an OD pair, the merge cannot disambiguate. The function
    # detects this and throws `ArgumentError` rather than silently picking one.
    #
    # We construct a synthetic instance by hand-duplicating a bundle in the
    # bundle vector of an existing tiny instance, using the keyword-arg
    # `Instance(; ...)` constructor to bypass the natural construction path
    # (which would not produce a duplicate). The resulting `dup_instance` is
    # not semantically valid for solving, but is good enough to exercise the
    # OD-uniqueness check in `merge_solutions`.
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    # Duplicate the first bundle to create a fake OD collision in the bundles
    # vector. Graph fields are reused as-is (the check fires before any graph
    # lookup, so the synthetic state never gets exercised).
    dup_bundles = vcat(instance.bundles, instance.bundles[1:1])
    dup_instance = Instance(;
        bundles=dup_bundles,
        network_graph=instance.network_graph,
        time_horizon_length=instance.time_horizon_length,
        time_step=instance.time_step,
        time_step_to_date=instance.time_step_to_date,
        time_space_graph=instance.time_space_graph,
        travel_time_graph=instance.travel_time_graph,
        # Reuses the original graphs, so the original cache stays valid.
        index_cache=instance.index_cache,
    )

    sol = greedy_heuristic(instance)
    sub_sol = greedy_heuristic(instance)

    # Duplicate in sub_instance triggers the error.
    @test_throws ArgumentError merge_solutions(sol, sub_sol, instance, dup_instance)

    # Duplicate in full_instance triggers the error too.
    @test_throws ArgumentError merge_solutions(sol, sub_sol, dup_instance, instance)
end
