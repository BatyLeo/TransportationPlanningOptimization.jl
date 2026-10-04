using Test
using Dates
using Graphs: Graphs
using SparseArrays: SparseArrays
using MetaGraphsNext: MetaGraphsNext, label_for
using TransportationPlanningOptimization

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# O1 -> X takes 3 days, O2 -> X takes 1 day. The big bundle (O1 -> D) fills the
# X -> D bin on day 3. The small one (O2 -> D) reaches X on day 1 and can only share that
# bin by looping X -> Y -> X until day 3, which raw Dijkstra does.
function looping_instance()
    nodes = [
        Node(; id="O1", node_type=:origin),
        Node(; id="O2", node_type=:origin),
        Node(; id="X", node_type=:other),
        Node(; id="Y", node_type=:other),
        Node(; id="D", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="O1", destination_id="X", cost=LinearArcCost(0), travel_time=Day(3)
        ),
        Arc(;
            origin_id="O2", destination_id="X", cost=LinearArcCost(0), travel_time=Day(1)
        ),
        Arc(; origin_id="X", destination_id="Y", cost=LinearArcCost(1), travel_time=Day(1)),
        Arc(; origin_id="Y", destination_id="X", cost=LinearArcCost(1), travel_time=Day(1)),
        Arc(;
            origin_id="Y", destination_id="D", cost=LinearArcCost(30), travel_time=Day(1)
        ),
        Arc(;
            origin_id="X",
            destination_id="D",
            cost=BinPackingArcCost(100, 10),
            travel_time=Day(1),
        ),
    ]
    commodities = [
        Commodity(;
            origin_id=o,
            destination_id="D",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(5),
            size=s,
        ) for (o, s) in (("O1", 5.0), ("O2", 1.0))
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

@testset "is_elementary_path" begin
    spatial = [1, 1, 2, 2, 1, 3]  # TTG code -> physical node
    @test TPO.is_elementary_path(Int[], spatial)
    @test TPO.is_elementary_path([3], spatial)
    @test TPO.is_elementary_path([1, 2, 3], spatial)       # X X Y
    @test !TPO.is_elementary_path([1, 3, 5], spatial)      # X Y X
    @test !TPO.is_elementary_path([1, 3, 4, 5], spatial)   # X Y Y X
    path = [1, 3, 4, 5]
    TPO.is_elementary_path(path, spatial)
    @test @allocated(TPO.is_elementary_path(path, spatial)) == 0
end

@testset "bundle_shortest_path avoids loops that Dijkstra takes" begin
    instance = looping_instance()
    ttg = instance.travel_time_graph
    sol = SolutionState(instance)
    spatial = instance.index_cache.ttg_code_to_spatial_code

    # Insert the big bundle (index of O1 -> D) first, as greedy does.
    big = findfirst(b -> b.origin_id == "O1", instance.bundles)
    small = findfirst(b -> b.origin_id == "O2", instance.bundles)
    TPO.insert_bundle!(sol, instance, big)

    TPO.update_bundle_cost_matrix!(sol, instance, small)
    origin, dest = ttg.origin_codes[small], ttg.destination_codes[small]
    parents, _ = TPO.bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=dest)
    raw = TPO.trace_path(parents, origin, dest)
    @test !TPO.is_elementary_path(raw, spatial)

    path = TPO.bundle_shortest_path(instance, origin, dest)
    @test TPO.is_elementary_path(path, spatial)
    ids = [label_for(ttg.graph, v)[1] for v in path]
    @test unique(ids) == ["O2", "X", "Y", "D"]
end

@testset "greedy_heuristic returns elementary paths" begin
    instance = looping_instance()
    sol = greedy_heuristic(instance; show_progress=false)
    spatial = instance.index_cache.ttg_code_to_spatial_code
    @test is_feasible(sol, instance; verbose=true)
    @test all(p -> TPO.is_elementary_path(p, spatial), sol.bundle_paths)
    # Big bundle pays one bin (100), small one pays X -> Y -> D (1 + 30) instead of a bin.
    @test cost(sol) ≈ 131.0
end

@testset "is_feasible rejects a looping solution" begin
    instance = looping_instance()
    ttg = instance.travel_time_graph
    small = findfirst(b -> b.origin_id == "O2", instance.bundles)
    # Hand-built loop: reroute the small bundle with raw Dijkstra.
    looped = greedy_heuristic(instance; show_progress=false)
    TPO.remove_bundle_path!(looped, instance, small)
    TPO.update_bundle_cost_matrix!(looped, instance, small)
    origin, dest = ttg.origin_codes[small], ttg.destination_codes[small]
    parents, _ = TPO.bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=dest)
    raw = TPO.trace_path(parents, origin, dest)
    TPO.add_bundle_path!(looped, instance, small, raw)
    @test !is_feasible(looped, instance)
    @test_logs (:warn, r"elementary") match_mode = :any is_feasible(
        looped, instance; verbose=true
    )
end

# Path O -> P -> H -> C -> D. The raw cheapest H -> C segment is H -> P -> C (cost 0),
# which is elementary but loops on P once spliced into the path. Travel times below the
# time step floor to zero steps, so H -> P and H -> Q take no step.
function splice_instance(;
    with_detour::Bool, with_shortcut::Bool=true, hc_capacity::Int=typemax(Int)
)
    nodes = [
        Node(; id="O", node_type=:origin),
        Node(; id="P", node_type=:other),
        Node(; id="H", node_type=:other),
        Node(; id="C", node_type=:other),
        Node(; id="Q", node_type=:other),
        Node(; id="D", node_type=:destination),
    ]
    arc(o, d, c, t=Day(1), cap=typemax(Int)) = Arc(;
        origin_id=o,
        destination_id=d,
        cost=LinearArcCost(c),
        travel_time=t,
        capacity=cap,
    )
    arcs = Arc[
        arc("O", "P", 1),
        arc("P", "H", 1),
        arc("H", "C", 10, Day(1), hc_capacity),
        arc("C", "D", 1),
    ]
    if with_shortcut
        push!(arcs, arc("H", "P", 0, Hour(1)), arc("P", "C", 0))
    end
    if with_detour
        push!(arcs, arc("H", "Q", 2, Hour(1)), arc("Q", "C", 3))
    end
    commodity = Commodity(;
        origin_id="O",
        destination_id="D",
        quantity=1,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(4),
        size=1.0,
    )
    return Instance(nodes, arcs, [commodity], Day(1))
end

# SolutionState holding the path O -> P -> H -> C -> D and the (H, C) arc codes.
function splice_solution(instance)
    ttg = instance.travel_time_graph
    code(id, τ) = MetaGraphsNext.code_for(ttg.graph, (id, τ))
    path = [
        code("O", 0), code("P", 1), code("H", 2), code("C", 3), ttg.destination_codes[1]
    ]
    sol = SolutionState(instance)
    TPO.add_bundle_path!(sol, instance, 1, path)
    return sol, path[3], path[4]
end

# Raw Dijkstra segment from h to c for the merged bundle, with the path lifted. Asserts
# the premise: the segment is elementary but its splice into the old path is not.
function test_raw_segment_premise(instance)
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    sol, h, c = splice_solution(instance)
    old_path = copy(sol.bundle_paths[1])
    TPO.remove_bundle_path!(sol, instance, 1)
    virtual_bundle, virtual_arcs = TPO.merge_bundles(instance, [1])
    TPO.update_bundle_cost_matrix!(
        sol, instance, virtual_bundle, virtual_arcs, CheapestMode()
    )
    parents, _ = TPO.bundle_dijkstra(ttg.graph, h, ttg.cost_matrix; dst=c)
    segment = TPO.trace_path(parents, h, c)
    @test TPO.is_elementary_path(segment, spatial)
    @test !TPO.is_elementary_path(TPO.splice_path(old_path, h, c, segment), spatial)
    return nothing
end

@testset "two-node splice cancelled when the elementary segment is no cheaper" begin
    instance = splice_instance(; with_detour=false)
    spatial = instance.index_cache.ttg_code_to_spatial_code
    test_raw_segment_premise(instance)
    sol, h, c = splice_solution(instance)
    @test is_feasible(sol, instance; verbose=true)
    old_cost = cost(sol)
    old_paths = copy.(sol.bundle_paths)

    @test TPO.two_node_common_incremental!(sol, instance, h, c; refine=false) == 0.0
    @test sol.bundle_paths == old_paths
    @test cost(sol) ≈ old_cost
    @test all(p -> TPO.is_elementary_path(p, spatial), sol.bundle_paths)
end

@testset "two-node splice accepts a cheaper elementary detour" begin
    instance = splice_instance(; with_detour=true)
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    test_raw_segment_premise(instance)
    sol, h, c = splice_solution(instance)
    old_cost = cost(sol)

    saved = TPO.two_node_common_incremental!(sol, instance, h, c; refine=false)
    @test saved ≈ 5.0  # H -> C (10) replaced by H -> Q -> C (5)
    @test cost(sol) ≈ old_cost - 5.0
    ids = [label_for(ttg.graph, v)[1] for v in sol.bundle_paths[1]]
    @test ["H", "Q", "C"] == ids[findfirst(==("H"), ids):findfirst(==("C"), ids)]
    @test all(p -> TPO.is_elementary_path(p, spatial), sol.bundle_paths)
    @test is_feasible(sol, instance; verbose=true)
end

@testset "two-node move without a usable segment restores the lifted bundles" begin
    # H -> C is too small for the bundle, so it costs Inf. Without the shortcut arcs
    # Dijkstra finds no segment. With them the raw segment H -> P -> C loops once
    # spliced and the elementary search, which must avoid P, finds nothing either.
    for with_shortcut in (false, true)
        instance = splice_instance(; with_detour=false, with_shortcut, hc_capacity=0)
        with_shortcut && test_raw_segment_premise(instance)
        sol, h, c = splice_solution(instance)
        old_cost = cost(sol)
        old_paths = copy.(sol.bundle_paths)

        @test TPO.two_node_common_incremental!(sol, instance, h, c; refine=false) == 0.0
        @test sol.bundle_paths == old_paths
        @test cost(sol) ≈ old_cost
    end
end

@testset "elementary_shortest_path on a hand-built graph" begin
    # Vertices s=1, a1=2, b=3, v=4, t=5, a2=6 with a1 and a2 on the same physical node.
    spatial = [1, 2, 3, 4, 5, 2]
    arcs = [(1, 2, 1.0), (2, 4, 1.0), (1, 3, 5.0), (3, 4, 1.0), (4, 6, 1.0), (6, 5, 1.0)]
    g = Graphs.SimpleDiGraph(6)
    for (u, v, _) in arcs
        Graphs.add_edge!(g, u, v)
    end
    costs = SparseArrays.sparse(first.(arcs), getindex.(arcs, 2), last.(arcs), 6, 6)
    parents, _ = TPO.bundle_dijkstra(g, 1, costs; dst=5)
    @test TPO.trace_path(parents, 1, 5) == [1, 2, 4, 6, 5]  # loops on a1/a2
    # Two labels reach v with incomparable visited sets, only the one through b survives.
    @test TPO.elementary_shortest_path(g, costs, spatial, 1, 5) == [1, 3, 4, 6, 5]
    @test TPO.elementary_shortest_path(g, costs, spatial, 1, 5; visited=BitSet([3])) ==
        Int[]
end

@testset "lazy reinsertion keeps the elementary path" begin
    instance = looping_instance()
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    sol = greedy_heuristic(instance; show_progress=false)
    small = findfirst(b -> b.origin_id == "O2", instance.bundles)
    old_path = copy(sol.bundle_paths[small])
    old_cost = cost(sol)
    adj = TPO._compute_bundle_adjacencies(ttg, length(instance.bundles))[small]

    # Premise: the lazy search alone finds the loop (cost 2).
    probe = greedy_heuristic(instance; show_progress=false)
    TPO.remove_bundle_path!(probe, instance, small)
    origin, dest = ttg.origin_codes[small], ttg.destination_codes[small]
    parents = TPO._lazy_bundle_dijkstra!(
        probe, instance, small, origin, dest, CheapestMode(), TPO.BinPackingBuffer(), adj
    )
    @test !TPO.is_elementary_path(TPO.trace_path(parents, origin, dest), spatial)

    # Without a buffer pool the lazy branch runs and must fall back to the elementary path.
    saved = TPO._try_reinsert_bundle!(sol, instance, small, CheapestMode(); bundle_adj=adj)
    @test saved == 0.0
    @test sol.bundle_paths[small] == old_path
    @test TPO.is_elementary_path(sol.bundle_paths[small], spatial)
    @test cost(sol) ≈ old_cost
end

@testset "bundle_shortest_path equals Dijkstra when there is no loop" begin
    for instance in (TestFixtures.tiny_instance(), TestFixtures.small_instance())
        ttg = instance.travel_time_graph
        sol = SolutionState(instance)
        for i in eachindex(instance.bundles)
            TPO.update_bundle_cost_matrix!(sol, instance, i)
            origin, dest = ttg.origin_codes[i], ttg.destination_codes[i]
            parents, _ = TPO.bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=dest)
            @test TPO.bundle_shortest_path(instance, origin, dest) ==
                TPO.trace_path(parents, origin, dest)
        end
    end
end
