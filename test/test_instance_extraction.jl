using Test
using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound: parse_inbound_instance
using Dates
using MetaGraphsNext

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "TPO.extract_filtered_instance shrinks bundle count" begin
    # Structural check: doesn't depend on scale, only on `filt` having some
    # multi-hop bundles, which `tiny` already provides (verified: all 4
    # bundles keep a multi-hop path here).
    instance = TestFixtures.tiny_instance()
    filt = lower_bound_filtering(instance; show_progress=false)
    sub = TPO.extract_filtered_instance(instance, filt)

    expected_kept = count(
        p -> TPO._direct_arc_position(instance.index_cache, p) == 0, filt.bundle_paths
    )
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

@testset "TPO.extract_filtered_instance preserves graph consistency" begin
    # Structural check: graph-field propagation doesn't depend on scale.
    instance = TestFixtures.tiny_instance()
    filt = lower_bound_filtering(instance; show_progress=false)
    sub = TPO.extract_filtered_instance(instance, filt)

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

@testset "TPO.extract_filtered_instance with all single-hop bundles logs an info message" begin
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
    # The origin -> destination edges are not real arcs: the `SolutionState(bundle_paths, instance)`
    # constructor rejects them, so the paths are set directly.
    @test_throws ArgumentError SolutionState(direct_paths, instance)
    fake_filt = SolutionState(instance)
    fake_filt.bundle_paths .= direct_paths

    @test_logs (:info,) match_mode = :any TPO.extract_filtered_instance(instance, fake_filt)
    sub = (@test_logs (:info,) match_mode = :any TPO.extract_filtered_instance(
        instance, fake_filt
    ))
    @test bundle_count(sub) == 0
end

@testset "TPO.merge_solutions produces a feasible full solution" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    filt = lower_bound_filtering(instance; show_progress=false)
    sub = TPO.extract_filtered_instance(instance, filt)
    sub_sol = greedy_heuristic(sub; show_progress=false)

    merged = TPO.merge_solutions(filt, sub_sol, instance, sub)

    @test is_feasible(merged, instance; verbose=true)
end

@testset "filter then greedy then merge cheaper than vanilla greedy on small" begin
    # Explicit cost comparison: needs scale, kept on `small`.
    instance = TestFixtures.small_instance()

    greedy_cost = cost(greedy_heuristic(instance; show_progress=false))

    filt = lower_bound_filtering(instance; show_progress=false)
    sub = TPO.extract_filtered_instance(instance, filt)
    sub_sol = greedy_heuristic(sub; show_progress=false)
    merged = TPO.merge_solutions(filt, sub_sol, instance, sub)

    @test is_feasible(merged, instance)
    # The filter-greedy pipeline should not blow up cost relative to vanilla greedy.
    # We tolerate up to 1.5x because filtering is approximate (relaxed LB on shared arcs),
    # but in practice it should usually be comparable or better.
    @test cost(merged) <= 1.5 * greedy_cost
end

@testset "TPO.merge_solutions errors on duplicate OD pairs" begin
    # `TPO.merge_solutions` keys by `(origin_id, destination_id)` and assumes the
    # default `group_by`. If `Instance(...; group_by=f)` is used such that two
    # bundles share an OD pair, the merge cannot disambiguate. The function
    # detects this and throws `ArgumentError` rather than silently picking one.
    #
    # We construct a synthetic instance by hand-duplicating a bundle in the
    # bundle vector of an existing tiny instance, using the keyword-arg
    # `Instance(; ...)` constructor to bypass the natural construction path
    # (which would not produce a duplicate). The resulting `dup_instance` is
    # not semantically valid for solving, but is good enough to exercise the
    # OD-uniqueness check in `TPO.merge_solutions`.
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
        input=instance.input,
        commodity_to_order=instance.commodity_to_order,
    )

    sol = greedy_heuristic(instance; show_progress=false)
    sub_sol = greedy_heuristic(instance; show_progress=false)

    # Duplicate in sub_instance triggers the error.
    @test_throws ArgumentError TPO.merge_solutions(sol, sub_sol, instance, dup_instance)

    # Duplicate in full_instance triggers the error too.
    @test_throws ArgumentError TPO.merge_solutions(sol, sub_sol, dup_instance, instance)
end

"""
Topology: F (A->B, size 3, filtered out, direct path) and K (A->D2 via B,
size 4, kept) share arc A->B (capacity 5).
"""
function fb_shared_arc_instance()
    nodes = [
        Node(; id="A", node_type=:origin),
        Node(; id="B", node_type=:other),
        Node(; id="D2", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=5,
        ),
        Arc(;
            origin_id="B", destination_id="D2", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=3.0,
        ),
        Commodity(;
            origin_id="A",
            destination_id="D2",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=4.0,
        ),
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

@testset "TPO.preload_filtered_bundles reserves a filtered bundle's capacity before any routing" begin
    # Unit test for the pre-load helper in isolation: build `sub_instance` and a
    # plain `SolutionState(sub_instance)`, call the helper, and check the shared
    # arc's assignment already carries the filtered bundle's size, before any
    # bundle of `sub_instance` is routed.
    instance = fb_shared_arc_instance()

    filt = lower_bound_filtering(instance; show_progress=false)
    sub = TPO.extract_filtered_instance(instance, filt)
    @test bundle_count(sub) == 1  # only K is kept, F is filtered out

    sol = TPO.preload_filtered_bundles(filt, instance, sub)
    @test all(isempty, sol.bundle_paths)  # preload must not touch bundle_paths

    # The sub-instance's A->B edge (at F's departure time step, t=1) must
    # already carry F's 3.0 units, reserved before K is ever routed.
    cache = sub.index_cache
    sa = MetaGraphsNext.code_for(sub.network_graph.graph, "A")
    sb = MetaGraphsNext.code_for(sub.network_graph.graph, "B")
    u_tsg = cache.spatial_code_and_time_to_tsg_code[sa, 1]
    v_tsg = cache.spatial_code_and_time_to_tsg_code[sb, 2]
    @test total_size_of(sol.assignments[(u_tsg, v_tsg)]) == 3.0
end

@testset "TPO.merge_solutions throws ArgumentError on a capacity-infeasible merge" begin
    # Hand-build an infeasible pair: skip the pre-load fix entirely (route K
    # via `greedy_heuristic` from a bare empty solution, bypassing
    # `preload_filtered_bundles`) so K's real solve doesn't know about F's
    # reservation, and their combined load overflows the shared arc A->B
    # (capacity 5, F=3, K=4).
    instance = fb_shared_arc_instance()

    filt = lower_bound_filtering(instance; show_progress=false)
    sub = TPO.extract_filtered_instance(instance, filt)
    @test bundle_count(sub) == 1  # only K is kept, F is filtered out
    # No pre-load: K is routed from a bare empty starting solution, blind to
    # F's already-committed capacity.
    sub_sol = greedy_heuristic(sub; show_progress=false)

    @test_throws ArgumentError TPO.merge_solutions(filt, sub_sol, instance, sub)
end

struct MergeGroupInfo
    model::String
end

@testset "TPO.merge_solutions supports non-default group_by (same OD, distinct groups)" begin
    # With a non-default `group_by`, two bundles can share an `(origin,
    # destination)` pair while differing by group. `merge_solutions` keys on the
    # full `(origin, destination, group)` triple, so it disambiguates them
    # instead of throwing (which the old OD-only keying would have done).
    nodes = [
        Node(; id="A", node_type=:origin, capacity=10, info=nothing),
        Node(; id="B", node_type=:destination, capacity=10, info=nothing),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            travel_time=Week(0),
            cost=LinearArcCost(1.0),
            info=nothing,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            quantity=1,
            arrival_date=DateTime(2024, 1, 1),
            max_delivery_time=Week(1),
            info=MergeGroupInfo("X"),
        ),
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            quantity=1,
            arrival_date=DateTime(2024, 1, 1),
            max_delivery_time=Week(1),
            info=MergeGroupInfo("Y"),
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Week(1); group_by=c -> c.info.model)

    # Two bundles on the same OD, disambiguated only by their group.
    @test bundle_count(instance) == 2
    @test Set(b.group for b in instance.bundles) == Set(["X", "Y"])

    sol = greedy_heuristic(instance; show_progress=false)
    # Merging the solution against itself must not throw on the OD collision and
    # must reproduce a feasible full solution.
    merged = TPO.merge_solutions(sol, sol, instance, instance)
    @test is_feasible(merged, instance; verbose=true)
    @test length(merged.bundle_paths) == 2
end

@testset "TPO.extract_filtered_instance maps input commodities to the sub-instance" begin
    instance = TestFixtures.tiny_instance()
    @test bundle_count(instance) == 4

    # Only the length of a bundle path matters to the extraction: 2 is dropped, 3 is kept
    function fake_filtering(inst, dropped)
        sol = SolutionState(inst)
        sol.bundle_paths .= [
            i in dropped ? Int[1, 2] : Int[1, 2, 3] for i in 1:bundle_count(inst)
        ]
        return sol
    end

    function check_sub(sub, parent, keep_idxs)
        @test sub.input === parent.input
        TestFixtures.check_input_links(sub; complete=false)
        for label in MetaGraphsNext.labels(sub.network_graph.graph)
            @test sub.network_graph.graph[label] === parent.network_graph.graph[label]
        end
        for (u, v) in MetaGraphsNext.edge_labels(sub.network_graph.graph)
            @test sub.network_graph.graph[u, v] === parent.network_graph.graph[u, v]
        end
        @test bundle_count(sub) == length(keep_idxs)
        for (k, (i, o)) in enumerate(parent.commodity_to_order)
            j = i == 0 ? nothing : findfirst(==(i), keep_idxs)
            if isnothing(j)
                @test sub.commodity_to_order[k] == (0, 0)
            else
                @test sub.commodity_to_order[k] == (j, o)
                @test sub.bundles[j].orders[o] === parent.bundles[i].orders[o]
            end
        end
    end

    # Drop bundles 1 and 3: kept bundles are re-indexed
    keep1 = [2, 4]
    sub1 = TPO.extract_filtered_instance(instance, fake_filtering(instance, [1, 3]))
    check_sub(sub1, instance, keep1)

    # Drop one more bundle from the sub-instance: entries already at (0, 0) stay there
    sub2 = TPO.extract_filtered_instance(sub1, fake_filtering(sub1, [1]))
    check_sub(sub2, sub1, [2])
    for (k, (i, o)) in enumerate(instance.commodity_to_order)
        expected = i == keep1[2] ? (1, o) : (0, 0)
        @test sub2.commodity_to_order[k] == expected
    end

    # All bundles dropped: every commodity maps to (0, 0) and the input is still shared
    empty_sub = (@test_logs (:info,) match_mode = :any TPO.extract_filtered_instance(
        instance, fake_filtering(instance, 1:bundle_count(instance))
    ))
    @test empty_sub.input === instance.input
    @test all(==((0, 0)), empty_sub.commodity_to_order)
    @test length(empty_sub.commodity_to_order) == length(instance.input.commodities)
end

@testset "TPO.extract_filtered_instance keeps trivial commodities dropped" begin
    instance = TestFixtures.trivial_instance("B")
    filt = lower_bound_filtering(instance; show_progress=false)
    sub = TPO.extract_filtered_instance(instance, filt)
    @test bundle_count(sub) == 1
    @test sub.commodity_to_order[3] == (0, 0)
    @test all(!=((0, 0)), sub.commodity_to_order[1:2])
end
