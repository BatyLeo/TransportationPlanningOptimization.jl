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
        Node(; id="O1"), Node(; id="O2"), Node(; id="X"), Node(; id="Y"), Node(; id="D")
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
        Node(; id="O"),
        Node(; id="P"),
        Node(; id="H"),
        Node(; id="C"),
        Node(; id="Q"),
        Node(; id="D"),
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
    virtual_bundle = TPO.merge_bundles(instance, [1])
    virtual_arcs = ttg.bundle_arcs[1]
    TPO.update_bundle_cost_matrix!(
        sol, instance, virtual_bundle, virtual_arcs, CheapestMode()
    )
    parents, _ = TPO.bundle_dijkstra(ttg.graph, h, ttg.cost_matrix; dst=c)
    segment = TPO.trace_path(parents, h, c)
    @test TPO.is_elementary_path(segment, spatial)
    @test !TPO.is_elementary_path(
        first(
            TPO.splice_path(
                old_path,
                findfirst(==(h), old_path),
                findfirst(==(c), old_path),
                segment,
                ttg,
            ),
        ),
        spatial,
    )
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

@testset "two-node fallback avoids the prefix but reuses the old slice interior" begin
    # Old path O -> P -> H -> M -> N -> C -> D with the slice H..C. The raw cheapest H -> C
    # segment H -> P -> C (cost 0) loops on P. The fallback must avoid P (prefix) and
    # may reuse M (old interior): H -> M -> C (2) beats H -> C (10).
    nodes = [
        Node(; id="O"),
        [Node(; id=id) for id in ("P", "H", "M", "N", "C")]...,
        Node(; id="D"),
    ]
    arc(o, d, c, t=Day(1)) =
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(c), travel_time=t)
    arcs = [
        arc("O", "P", 1),
        arc("P", "H", 1),
        arc("H", "M", 1, Hour(1)),
        arc("M", "N", 5, Hour(1)),
        arc("N", "C", 5),
        arc("M", "C", 1),
        arc("H", "C", 10),
        arc("C", "D", 1),
        arc("H", "P", 0, Hour(1)),
        arc("P", "C", 0),
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
    spatial = instance.index_cache.ttg_code_to_spatial_code
    code(id, τ) = MetaGraphsNext.code_for(ttg.graph, (id, τ))
    path = [
        code("O", 0),
        code("P", 1),
        code("H", 2),
        code("M", 2),
        code("N", 2),
        code("C", 3),
        ttg.destination_codes[1],
    ]
    sol = SolutionState([path], instance)
    c0 = cost(sol)
    @test TPO.bundles_through_nodes(sol, path[3], path[6]) == [(1, 3, 6)]

    saved = TPO.two_node_common_incremental!(sol, instance, path[3], path[6]; refine=false)
    @test saved ≈ 9.0  # H -> M -> N -> C (11) replaced by H -> M -> C (2)
    @test cost(sol) ≈ c0 - 9.0
    ids = [label_for(ttg.graph, v)[1] for v in sol.bundle_paths[1]]
    @test ids == ["O", "P", "H", "M", "C", "D"]
    @test all(p -> TPO.is_elementary_path(p, spatial), sol.bundle_paths)
    @test is_feasible(sol, instance; verbose=true)
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

# Cost of `path` under the cost matrix filled by `update_bundle_cost_matrix!`.
function matrix_path_cost(ttg, path)
    return sum(
        ttg.cost_matrix[path[k], path[k + 1]] for k in 1:(length(path) - 1); init=0.0
    )
end

# Lazy helpers priced with bundle `b` removed from a copy of `sol`.
function lazy_setup(instance, sol, b)
    state = copy(sol)
    TPO.remove_bundle_path!(state, instance, b)
    ttg = instance.travel_time_graph
    return state,
    ttg.origin_codes[b], ttg.destination_codes[b],
    TPO._bundle_adjacency(ttg, b)
end

@testset "lazy bundle path equals the cost matrix shortest path" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    ttg = instance.travel_time_graph
    buffer = TPO.BinPackingBuffer()
    workspace = TPO.DijkstraWorkspace(Graphs.nv(ttg.graph))
    for b in 1:6
        state, origin, dest, adj = lazy_setup(instance, sol, b)
        path = TPO._lazy_bundle_path!(
            state, instance, b, origin, dest, CheapestMode(), buffer, adj; workspace
        )
        TPO.update_bundle_cost_matrix!(state, instance, b, CheapestMode())
        expected = TPO.bundle_shortest_path(instance, origin, dest)
        @test matrix_path_cost(ttg, path) ≈ matrix_path_cost(ttg, expected)
    end
end

@testset "lazy bundle path excludes an arc" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    buffer = TPO.BinPackingBuffer()
    for b in 1:6
        state, origin, dest, adj = lazy_setup(instance, sol, b)
        path = sol.bundle_paths[b]
        k = findfirst(k -> spatial[path[k]] != spatial[path[k + 1]], 1:(length(path) - 1))
        arc = (path[k], path[k + 1])
        new = TPO._lazy_bundle_path!(
            state, instance, b, origin, dest, CheapestMode(), buffer, adj; exclude=arc
        )
        TPO.update_bundle_cost_matrix!(state, instance, b, CheapestMode())
        ttg.cost_matrix[arc...] = Inf
        expected = TPO.bundle_shortest_path(instance, origin, dest)
        @test arc ∉ zip(new[1:(end - 1)], new[2:end])
        @test matrix_path_cost(ttg, new) ≈ matrix_path_cost(ttg, expected)
    end
end

@testset "lazy forced path goes through the arc at the cheapest cost" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    buffer = TPO.BinPackingBuffer()
    found = 0
    for b in 1:3
        state, origin, dest, adj = lazy_setup(instance, sol, b)
        TPO.update_bundle_cost_matrix!(state, instance, b, CheapestMode())
        parents_origin, dist_origin = TPO.bundle_dijkstra(
            ttg.graph, origin, ttg.cost_matrix
        )
        for arc in ttg.bundle_arcs[b][1:min(end, 15)]
            spatial[arc[1]] == spatial[arc[2]] && continue
            path = TPO._lazy_forced_path!(
                state, instance, b, arc, CheapestMode(), buffer, adj
            )
            isempty(path) && continue
            found += 1
            k = findfirst(==(arc[1]), path)
            @test !isnothing(k) && path[k + 1] == arc[2]
            @test TPO.is_elementary_path(path, spatial)
            parents_arc, dist_arc = TPO.bundle_dijkstra(ttg.graph, arc[2], ttg.cost_matrix)
            expected = dist_origin[arc[1]] + ttg.cost_matrix[arc...] + dist_arc[dest]
            @test matrix_path_cost(ttg, path) >= expected - 1e-9
            # Equal unless the two cheapest legs together revisit a physical node.
            joined = vcat(
                TPO.trace_path(parents_origin, origin, arc[1]),
                TPO.trace_path(parents_arc, arc[2], dest),
            )
            if TPO.is_elementary_path(joined, spatial)
                @test matrix_path_cost(ttg, path) ≈ expected
            end
        end
    end
    @test found >= 3
end

@testset "lazy helpers keep the path elementary" begin
    instance = looping_instance()
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    g = ttg.graph
    sol = greedy_heuristic(instance; show_progress=false)
    small = findfirst(b -> b.origin_id == "O2", instance.bundles)
    state, origin, dest, adj = lazy_setup(instance, sol, small)
    buffer = TPO.BinPackingBuffer()
    # The cheapest lazy path loops X -> Y -> X to share the big bin, the helper must not.
    path = TPO._lazy_bundle_path!(
        state, instance, small, origin, dest, CheapestMode(), buffer, adj
    )
    @test !isempty(path)
    @test TPO.is_elementary_path(path, spatial)
    # Forcing Y -> X would revisit X: no elementary path goes through it.
    arcs_to(from, to) = [
        a for a in ttg.bundle_arcs[small] if
        label_for(g, a[1])[1] == from && label_for(g, a[2])[1] == to
    ]
    forced = [
        TPO._lazy_forced_path!(state, instance, small, a, CheapestMode(), buffer, adj) for
        a in arcs_to("Y", "X")
    ]
    @test !isempty(forced) && all(isempty, forced)
    # Forcing X -> Y is fine.
    forced = filter(
        !isempty,
        [
            TPO._lazy_forced_path!(state, instance, small, a, CheapestMode(), buffer, adj)
            for a in arcs_to("X", "Y")
        ],
    )
    @test !isempty(forced)
    @test all(p -> TPO.is_elementary_path(p, spatial), forced)
end

@testset "lazy forced path respects forbidden arcs and nodes" begin
    for kwargs in ((; forbidden_arcs=[("B", "C")]), (; forbidden_node_ids=["B"]))
        nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C")]
        arcs = [
            Arc(;
                origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(1)
            ) for (o, d) in (("A", "B"), ("B", "C"), ("A", "C"))
        ]
        commodity = Commodity(;
            origin_id="A",
            destination_id="C",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=1.0,
            kwargs...,
        )
        instance = Instance(nodes, arcs, [commodity], Day(1))
        sol = SolutionState(instance)
        ttg = instance.travel_time_graph
        g = ttg.graph
        adj = TPO._bundle_adjacency(ttg, 1)
        buffer = TPO.BinPackingBuffer()
        via_b = [
            a for a in ttg.bundle_arcs[1] if
            label_for(g, a[1])[1] == "B" || label_for(g, a[2])[1] == "B"
        ]
        @test !isempty(via_b)
        for a in via_b
            @test isempty(
                TPO._lazy_forced_path!(sol, instance, 1, a, CheapestMode(), buffer, adj)
            )
        end
    end
end

@testset "lazy bundle path avoids an excluded arc when it falls back" begin
    instance = looping_instance()
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    sol = greedy_heuristic(instance; show_progress=false)
    small = findfirst(b -> b.origin_id == "O2", instance.bundles)
    state, origin, dest, adj = lazy_setup(instance, sol, small)
    buffer = TPO.BinPackingBuffer()
    args = (state, instance, small, origin, dest, CheapestMode(), buffer, adj)
    path = TPO._lazy_bundle_path!(args...)
    parents = TPO._lazy_bundle_dijkstra!(args...)
    looping = TPO.trace_path(parents, origin, dest)
    # An arc of the elementary path that the looping lazy path does not use.
    arc = only(
        (path[k], path[k + 1]) for
        k in 1:(length(path) - 1) if spatial[path[k]] != spatial[path[k + 1]] &&
            (path[k], path[k + 1]) ∉ zip(looping[1:(end - 1)], looping[2:end])
    )
    new = TPO._lazy_bundle_path!(args...; exclude=arc)
    @test !isempty(new)
    @test arc ∉ zip(new[1:(end - 1)], new[2:end])
    @test TPO.is_elementary_path(new, spatial)
end

@testset "path searches stop at the deadline" begin
    n = 300
    g = Graphs.SimpleDiGraph(n)
    for v in 1:(n - 1)
        Graphs.add_edge!(g, v, v + 1)
    end
    costs = SparseArrays.sparse(1:(n - 1), 2:n, ones(n - 1), n, n)
    spatial = collect(1:n)
    @test length(TPO.elementary_shortest_path(g, costs, spatial, 1, n)) == n
    late = time() - 1.0
    @test isempty(TPO.elementary_shortest_path(g, costs, spatial, 1, n; deadline=late))

    instance = TestFixtures.small_instance()
    ttg = instance.travel_time_graph
    sol = SolutionState(instance)
    b = 1
    origin, dest = ttg.origin_codes[b], ttg.destination_codes[b]
    adj = TPO._bundle_adjacency(ttg, b)
    args = (sol, instance, b, origin, dest, CheapestMode(), TPO.BinPackingBuffer(), adj)
    @test !isempty(TPO._lazy_bundle_path!(args...))
    # The search settles enough nodes for a deadline check to be possible.
    ws = TPO.DijkstraWorkspace(Graphs.nv(ttg.graph))
    TPO._lazy_bundle_dijkstra!(args...; workspace=ws)
    @test count(ws.dists .< ws.dists[dest]) >= TPO.DEADLINE_CHECK_EVERY
    @test isempty(TPO._lazy_bundle_path!(args...; deadline=late))
    parents = TPO._lazy_bundle_dijkstra!(args...; deadline=late)
    @test isempty(TPO.trace_path(parents, origin, dest))
end
