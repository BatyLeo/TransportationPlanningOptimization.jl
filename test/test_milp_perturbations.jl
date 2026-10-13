using Test
using TransportationPlanningOptimization
using Dates
using MetaGraphsNext
using Random
using JuMP: JuMP

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# Two origins O1 and O2 send a size 5 commodity to D. Each direct arc costs one bin of 10.
# Routing both through the hub H costs 1 + 1 + one shared bin of 10 (12 instead of 20),
# which greedy insertion misses because it sees 11 against 10 for each bundle alone.
function hub_instance(;
    hub_capacity::Int=typemax(Int), forbidden_node_ids=String[], arrival::Bool=false
)
    nodes = [Node(; id="O1"), Node(; id="O2"), Node(; id="H"), Node(; id="D")]
    bin = BinPackingArcCost(10.0, 10)
    arcs = [
        Arc(; origin_id="O1", destination_id="D", cost=bin, travel_time=Day(1)),
        Arc(; origin_id="O2", destination_id="D", cost=bin, travel_time=Day(1)),
        Arc(;
            origin_id="O1", destination_id="H", cost=LinearArcCost(0.2), travel_time=Day(1)
        ),
        Arc(;
            origin_id="O2", destination_id="H", cost=LinearArcCost(0.2), travel_time=Day(1)
        ),
        Arc(;
            origin_id="H",
            destination_id="D",
            cost=bin,
            travel_time=Day(1),
            capacity=hub_capacity,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id=o,
            destination_id="D",
            quantity=1,
            (
                arrival ? (; arrival_date=DateTime(2021, 1, 3)) :
                (; departure_date=DateTime(2021, 1, 1))
            )...,
            max_delivery_time=Day(2),
            size=5.0,
            forbidden_node_ids=(o == "O1" ? forbidden_node_ids : String[]),
        ) for o in ("O1", "O2")
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

function spatial_ids(instance, path)
    g = instance.travel_time_graph.graph
    return [MetaGraphsNext.label_for(g, c)[1] for c in path]
end

function elementary_paths(sol, instance)
    spatial = instance.index_cache.ttg_code_to_spatial_code
    return all(TPO.is_elementary_path(p, spatial) for p in sol.bundle_paths)
end

@testset "MILP consolidates what greedy insertion misses" begin
    instance = hub_instance()
    sol = greedy_heuristic(instance; show_progress=false)
    @test cost(sol) ≈ 20.0
    before = cost(sol)
    (inc, n) = perturbate!(sol, instance, ArcFlowMILPPerturbation(; time_limit=10.0))
    @test n == 2
    @test inc ≈ -8.0
    @test cost(sol) - before ≈ inc
    @test cost(sol) ≈ 12.0
    @test is_feasible(sol, instance)
    @test all("H" in spatial_ids(instance, p) for p in sol.bundle_paths)
    @test elementary_paths(sol, instance)
end

@testset "MILP respects forbidden nodes" begin
    instance = hub_instance(; forbidden_node_ids=["H"])
    sol = greedy_heuristic(instance; show_progress=false)
    (inc, n) = perturbate!(sol, instance, ArcFlowMILPPerturbation(; time_limit=10.0))
    @test (inc, n) == (0.0, 0)
    @test !("H" in spatial_ids(instance, sol.bundle_paths[1]))
    @test is_feasible(sol, instance)
end

@testset "MILP respects forbidden arcs" begin
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C")]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="B", destination_id="C", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="C", cost=LinearArcCost(5.0), travel_time=Day(1)
        ),
    ]
    commodity = Commodity(;
        origin_id="A",
        destination_id="C",
        quantity=1,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(2),
        size=1.0,
        forbidden_arcs=[("B", "C")],
    )
    instance = Instance(nodes, arcs, [commodity], Day(1))
    sol = greedy_heuristic(instance; show_progress=false)
    perturbate!(sol, instance, ArcFlowMILPPerturbation(; time_limit=10.0))
    @test spatial_ids(instance, sol.bundle_paths[1]) == ["A", "C"]
    @test is_feasible(sol, instance)
end

@testset "MILP respects finite arc capacities" begin
    instance = hub_instance(; hub_capacity=7)
    sol = greedy_heuristic(instance; show_progress=false)
    perturbate!(sol, instance, ArcFlowMILPPerturbation(; time_limit=10.0))
    @test is_feasible(sol, instance)
    @test cost(sol) >= 20.0 - 1e-9
end

# A seed for which only the group of bundle `b` is selected under the given cap.
function seed_selecting(sol, instance, p, b)
    return findfirst(1:50) do seed
        return TPO._select_milp_bundles(sol, instance, p, Random.MersenneTwister(seed))[1] ==
               [b]
    end
end

# Number of model variables of a bundle alone: its arcs and its bin edges.
function milp_size(instance, b)
    arcs = TPO._milp_bundle_arcs(instance, b)
    bins = Set(e for (i, edges) in enumerate(arcs.edges) if arcs.binned[i] for e in edges)
    return length(arcs.u) + length(bins)
end

# `sol` with bundle `b` moved to the cheapest path that avoids every non-waiting edge of
# its current path.
function detour_solution(sol, instance, b)
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    old = copy(sol.bundle_paths[b])
    TPO.remove_bundle_path!(sol, instance, b)
    TPO.update_bundle_cost_matrix!(sol, instance, b)
    for (u, v) in zip(old[1:(end - 1)], old[2:end])
        spatial[u] != spatial[v] && (ttg.cost_matrix[u, v] = Inf)
    end
    path = TPO.bundle_shortest_path(instance, ttg.origin_codes[b], ttg.destination_codes[b])
    TPO.add_bundle_path!(sol, instance, b, path)
    return sol
end

@testset "MILP perturbation on a benchmark instance" begin
    TestFixtures.reset!()
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    greedy_cost = cost(sol)
    b = 1
    detour_solution(sol, instance, b)
    before = cost(sol)
    # The greedy path of the bundle really costs less than its detour, and the model can
    # route it there.
    @test before > greedy_cost
    # The cap fits the bundle alone, the seed makes it the only one selected, so the
    # outcome does not depend on which bundles a lucky seed draws.
    p = ArcFlowMILPPerturbation(;
        group_by=x -> x === instance.bundles[b],
        max_variables=milp_size(instance, b) + 1,
        time_limit=60.0,
        mip_gap=0.0,
    )
    seed = seed_selecting(sol, instance, p, b)
    @test !isnothing(seed)
    (inc, n) = perturbate!(sol, instance, p; rng=Random.MersenneTwister(seed))
    @test n == 1
    @test inc < 0
    @test cost(sol) - before ≈ inc atol = 1e-6
    @test is_feasible(sol, instance)
    @test elementary_paths(sol, instance)
end

# Paths of the hub instance through H or directly, in the stored form (no end shortcuts).
function hub_path(instance, origin, via)
    g = instance.travel_time_graph.graph
    labels = via ? [(origin, 0), ("H", 1), ("D", 2)] : [(origin, 0), ("D", 1), ("D", 2)]
    path = [MetaGraphsNext.code_for(g, l) for l in labels]
    TPO._remove_shortcuts_from_path!(path, instance.travel_time_graph)
    return path
end

# O2 routed through the hub, O1 direct.
function hub_solution(instance)
    sol = TPO.SolutionState(instance)
    for (b, bundle) in enumerate(instance.bundles)
        path = hub_path(instance, bundle.origin_id, bundle.origin_id == "O2")
        TPO.add_bundle_path!(sol, instance, b, path)
    end
    return sol
end

@testset "MILP keeps the background load of the other bundles" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    @test cost(sol) ≈ 21.0
    o1 = findfirst(b -> b.origin_id == "O1", instance.bundles)
    # The arcs of O1, its 2 bin edges (O1 -> D and H -> D) and one spare variable. This cap
    # is too small for the group of O2.
    n_vars = length(TPO._milp_bundle_arcs(instance, o1).u) + 3
    p = ArcFlowMILPPerturbation(;
        group_by=b -> b.origin_id, time_limit=10.0, max_variables=n_vars
    )
    seed = seed_selecting(sol, instance, p, o1)
    @test !isnothing(seed)
    # O1 joins the bin of O2 on H -> D: 1 for its leg instead of a bin of 10.
    (inc, n) = perturbate!(sol, instance, p; rng=Random.MersenneTwister(seed))
    @test n == 1
    @test inc ≈ -9.0
    @test "H" in spatial_ids(instance, sol.bundle_paths[o1])
    @test is_feasible(sol, instance)
end

@testset "MILP keeps the background load within a finite capacity" begin
    instance = hub_instance(; hub_capacity=7)
    sol = hub_solution(instance)
    o1 = findfirst(b -> b.origin_id == "O1", instance.bundles)
    # Same cap as in the previous test.
    n_vars = length(TPO._milp_bundle_arcs(instance, o1).u) + 3
    p = ArcFlowMILPPerturbation(;
        group_by=b -> b.origin_id, time_limit=10.0, max_variables=n_vars
    )
    seed = seed_selecting(sol, instance, p, o1)
    @test !isnothing(seed)
    @test perturbate!(sol, instance, p; rng=Random.MersenneTwister(seed)) == (0.0, 0)
    @test !("H" in spatial_ids(instance, sol.bundle_paths[o1]))
    # The model itself keeps O1 off H -> D, the capacity guard of the callback is not needed.
    arcs_of = Dict(o1 => TPO._milp_bundle_arcs(instance, o1))
    model, x = TPO._arc_flow_model(p, sol, instance, [o1], arcs_of)
    JuMP.optimize!(model)
    path = TPO._arc_flow_paths(instance, [o1], arcs_of, JuMP.value.(x))[o1]
    @test !("H" in spatial_ids(instance, path))
    @test is_feasible(sol, instance)
end

@testset "The model forbids a path that revisits a node" begin
    nodes = [Node(; id="A"), Node(; id="B"), Node(; id="C"), Node(; id="D")]
    arc(o, d) =
        Arc(; origin_id=o, destination_id=d, cost=LinearArcCost(1.0), travel_time=Day(1))
    arcs = [arc("A", "B"), arc("B", "C"), arc("C", "B"), arc("B", "D")]
    commodity = Commodity(;
        origin_id="A",
        destination_id="D",
        quantity=1,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(4),
        size=1.0,
    )
    instance = Instance(nodes, arcs, [commodity], Day(1))
    sol = TPO.SolutionState(instance)
    g = instance.travel_time_graph.graph
    code(label) = MetaGraphsNext.code_for(g, label)
    function status(labels)
        codes = [code(l) for l in labels]
        arcs_of = TPO._milp_bundle_arcs(instance, 1)
        model, x = TPO._arc_flow_model(
            ArcFlowMILPPerturbation(; time_limit=10.0),
            sol,
            instance,
            [1],
            Dict(1 => arcs_of),
        )
        on = Set(zip(codes[1:(end - 1)], codes[2:end]))
        for k in eachindex(x)
            JuMP.fix(x[k], (arcs_of.u[k], arcs_of.v[k]) in on ? 1.0 : 0.0; force=true)
            JuMP.is_binary(x[k]) && JuMP.unset_binary(x[k])
        end
        JuMP.optimize!(model)
        return JuMP.termination_status(model)
    end
    revisit = [("A", 0), ("B", 1), ("C", 2), ("B", 3), ("D", 4)]
    simple = [("A", 0), ("B", 1), ("D", 2), ("D", 3), ("D", 4)]
    @test status(simple) == JuMP.OPTIMAL
    @test status(revisit) in (JuMP.INFEASIBLE, JuMP.INFEASIBLE_OR_UNBOUNDED)
end

@testset "An invalid recovered path is detected" begin
    instance = hub_instance()
    arcs_of = Dict(b => TPO._milp_bundle_arcs(instance, b) for b in 1:2)
    n = sum(length(a.u) for a in values(arcs_of))
    @test isnothing(TPO._arc_flow_paths(instance, [1, 2], arcs_of, zeros(n)))
    # The routing of the hub solution is a valid x.
    sol = hub_solution(instance)
    model, x = TPO._arc_flow_model(
        ArcFlowMILPPerturbation(; warm_start=true), sol, instance, [1, 2], arcs_of
    )
    start = JuMP.start_value.(x)
    paths = TPO._arc_flow_paths(instance, [1, 2], arcs_of, start)
    @test paths isa Dict
    @test [paths[b] for b in 1:2] == sol.bundle_paths
end

@testset "The warm start is a feasible solution of the model" begin
    for hub_capacity in (typemax(Int), 10)
        instance = hub_instance(; hub_capacity)
        sol = hub_solution(instance)
        arcs_of = Dict(b => TPO._milp_bundle_arcs(instance, b) for b in 1:2)
        model, x = TPO._arc_flow_model(
            ArcFlowMILPPerturbation(; warm_start=true), sol, instance, [1, 2], arcs_of
        )
        point = Dict(v => JuMP.start_value(v) for v in JuMP.all_variables(model))
        @test all(!isnothing, values(point))
        @test isempty(JuMP.primal_feasibility_report(model, point; atol=1e-6))
        # The current routing costs 1 + 1 + 10 (bin of H -> D) + 10 (direct bin of O1).
        @test JuMP.value(v -> point[v], JuMP.objective_function(model)) ≈ 21.0
    end
end

@testset "The warm start is feasible in arrival date mode" begin
    instance = hub_instance(; arrival=true)
    sol = greedy_heuristic(instance; show_progress=false)
    arcs_of = Dict(b => TPO._milp_bundle_arcs(instance, b) for b in 1:2)
    model, x = TPO._arc_flow_model(
        ArcFlowMILPPerturbation(; warm_start=true), sol, instance, [1, 2], arcs_of
    )
    point = Dict(v => JuMP.start_value(v) for v in JuMP.all_variables(model))
    @test all(!isnothing, values(point))
    @test isempty(JuMP.primal_feasibility_report(model, point; atol=1e-6))
end

@testset "A path that cannot be chained gives no warm start" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    # O1 stored with its destination node cut off the shortcut chain.
    sol.bundle_paths[1] = sol.bundle_paths[1][1:(end - 1)]
    arcs_of = Dict(b => TPO._milp_bundle_arcs(instance, b) for b in 1:2)
    p = ArcFlowMILPPerturbation(; warm_start=true)
    model, x = TPO._arc_flow_model(p, sol, instance, [1, 2], arcs_of)
    @test all(v -> isnothing(JuMP.start_value(v)), x)
end

@testset "A warm started solve never worsens the cost" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    p = ArcFlowMILPPerturbation(; time_limit=1e-3, warm_start=true)
    (inc, _) = perturbate!(sol, instance, p; rng=Random.MersenneTwister(1))
    @test inc <= 1e-9
    @test is_feasible(sol, instance)
end

@testset "A fixed path above an arc capacity is rolled back" begin
    for (capacity, accepted) in ((7, false), (typemax(Int), true))
        instance = hub_instance(; hub_capacity=capacity)
        sol = greedy_heuristic(instance; show_progress=false)
        sol0 = copy(sol)
        result = TPO._reroute_bundles!(
            sol, instance, [1, 2]; tolerance=Inf
        ) do s, inst, snapshots
            for (b, bundle) in enumerate(inst.bundles)
                TPO._add_fixed_path!(
                    s, inst, b, hub_path(inst, bundle.origin_id, true), snapshots
                )
            end
            return TPO._fits_capacities(s, inst, snapshots)
        end
        if accepted
            @test result == (-8.0, 2)
        else
            @test result == (0.0, 0)
            @test TestFixtures.same_state(sol, sol0)
        end
    end
end

@testset "A zero time limit leaves a valid state" begin
    instance = TestFixtures.tiny_instance()
    sol = TestFixtures.tiny_greedy()
    sol0 = copy(sol)
    p = ArcFlowMILPPerturbation(; time_limit=0.0)
    result = perturbate!(sol, instance, p; rng=Random.MersenneTwister(1))
    # Either the solver has no solution (nothing changes) or it found a valid accepted move.
    if result == (0.0, 0)
        @test TestFixtures.same_state(sol, sol0)
    else
        @test is_feasible(sol, instance)
    end
end

@testset "A call with too little time changes nothing, a normal call works" begin
    instance = hub_instance()
    for p in (
        ArcFlowMILPPerturbation(; time_limit=10.0),
        AttractReduceMILPPerturbation(; time_limit=10.0),
    )
        sol = hub_solution(instance)
        sol0 = copy(sol)
        @test perturbate!(
            sol, instance, p; rng=Random.MersenneTwister(1), time_limit=1e-3
        ) == (0.0, 0)
        @test TestFixtures.same_state(sol, sol0)

        (inc, n) = perturbate!(
            sol, instance, p; rng=Random.MersenneTwister(1), time_limit=60.0
        )
        @test n > 0
        @test inc < 0
        @test is_feasible(sol, instance)
    end
end

@testset "A cap below every group changes nothing" begin
    instance = TestFixtures.tiny_instance()
    sol = TestFixtures.tiny_greedy()
    sol0 = copy(sol)
    p = ArcFlowMILPPerturbation(; max_variables=1)
    @test perturbate!(sol, instance, p; rng=Random.MersenneTwister(1)) == (0.0, 0)
    @test TestFixtures.same_state(sol, sol0)
end

@testset "Multimodal arcs are rejected" begin
    instance = TestFixtures._leg_instance([(10.0, 1, 10), (5.0, 1, 10)], 1)
    sol = greedy_heuristic(instance; show_progress=false)
    @test_throws ArgumentError perturbate!(sol, instance, ArcFlowMILPPerturbation())
end

# TTG arc `from -> to` between the labeled nodes, as codes.
function hub_arc(instance, from, to)
    g = instance.travel_time_graph.graph
    return (MetaGraphsNext.code_for(g, from), MetaGraphsNext.code_for(g, to))
end

# Bundle indices of O1 and O2 (the bundles are not listed in origin order).
function hub_bundles(instance)
    return (
        findfirst(b -> b.origin_id == "O1", instance.bundles),
        findfirst(b -> b.origin_id == "O2", instance.bundles),
    )
end

@testset "Attract and reduce paths of an arc" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    sol0 = copy(sol)
    o1, o2 = hub_bundles(instance)
    arc = hub_arc(instance, ("H", 1), ("D", 2))
    paths = TPO._attract_reduce_paths(sol, instance, arc, [o1, o2], Set([o2]))
    # O1 is attracted to the hub, O2 is pushed off it.
    @test spatial_ids(instance, paths[o1]) == ["O1", "H", "D"]
    @test spatial_ids(instance, paths[o2]) == ["O2", "D"]
    @test TestFixtures.same_state(sol, sol0)
end

@testset "Attract consolidates bundles onto the hub" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    @test cost(sol) ≈ 21.0
    before = cost(sol)
    p = AttractReduceMILPPerturbation(; time_limit=10.0)
    (inc, n) = perturbate!(sol, instance, p; rng=Random.MersenneTwister(1))
    @test n == 1
    @test inc ≈ -9.0
    @test cost(sol) - before ≈ inc
    @test all("H" in spatial_ids(instance, path) for path in sol.bundle_paths)
    @test is_feasible(sol, instance)
    @test elementary_paths(sol, instance)
end

@testset "Reduce moves a bundle off an expensive arc" begin
    # O1 may not use the hub, so only O2 can be pushed off H -> D.
    instance = hub_instance(; forbidden_node_ids=["H"])
    sol = hub_solution(instance)
    o1, o2 = hub_bundles(instance)
    before = cost(sol)
    paths = TPO._attract_reduce_paths(
        sol, instance, hub_arc(instance, ("H", 1), ("D", 2)), [o1, o2], Set([o2])
    )
    @test collect(keys(paths)) == [o2]
    p = AttractReduceMILPPerturbation(; time_limit=10.0)
    (inc, n) = perturbate!(sol, instance, p; rng=Random.MersenneTwister(1))
    @test (n, inc) == (1, -1.0)
    @test cost(sol) - before ≈ inc
    @test spatial_ids(instance, sol.bundle_paths[o2]) == ["O2", "D"]
    @test !("H" in spatial_ids(instance, sol.bundle_paths[o1]))
    @test is_feasible(sol, instance)
end

@testset "Attract reduce model chooses by cost" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    o1, o2 = hub_bundles(instance)
    arc = hub_arc(instance, ("H", 1), ("D", 2))
    paths = TPO._attract_reduce_paths(sol, instance, arc, [o1, o2], Set([o2]))
    p = AttractReduceMILPPerturbation(; time_limit=10.0, warm_start=true)
    # Alone, pushing O2 off the hub saves 1. With both, attracting O1 saves 9.
    model, z = TPO._attract_reduce_model(p, sol, instance, [o2], paths)
    JuMP.optimize!(model)
    @test JuMP.value.(z) ≈ [1.0]
    @test JuMP.objective_value(model) ≈ 9.0
    model, z = TPO._attract_reduce_model(p, sol, instance, sort([o1, o2]), paths)
    JuMP.optimize!(model)
    @test JuMP.value.(z) ≈ [b == o1 ? 1.0 : 0.0 for b in sort([o1, o2])]
end

@testset "Attract reduce respects finite capacities" begin
    instance = hub_instance(; hub_capacity=7)
    sol = hub_solution(instance)
    p = AttractReduceMILPPerturbation(; time_limit=10.0)
    before = cost(sol)
    (inc, _) = perturbate!(sol, instance, p; rng=Random.MersenneTwister(1))
    @test cost(sol) - before ≈ inc
    @test is_feasible(sol, instance)
    @test count(path -> "H" in spatial_ids(instance, path), sol.bundle_paths) <= 1
end

@testset "Attract reduce changes nothing without a gain or a candidate" begin
    instance = hub_instance()
    # Both bundles direct: the only moves cost 11 against 10.
    sol = greedy_heuristic(instance; show_progress=false)
    p = AttractReduceMILPPerturbation(; time_limit=10.0)
    sol0 = copy(sol)
    @test perturbate!(sol, instance, p; rng=Random.MersenneTwister(1)) == (0.0, 0)
    @test TestFixtures.same_state(sol, sol0)
    # No routed bundle, so no candidate arc.
    sol = TPO.SolutionState(instance)
    @test perturbate!(sol, instance, p; rng=Random.MersenneTwister(1)) == (0.0, 0)
end

@testset "Attract reduce falls back on the arc with the most new paths" begin
    # H -> D could take both bundles, but O1 may not use the hub, so only one gets a path.
    instance = hub_instance(; forbidden_node_ids=["H"])
    sol = hub_solution(instance)
    p = AttractReduceMILPPerturbation(; time_limit=10.0, min_candidate_ratio=0.6)
    @test perturbate!(sol, instance, p; rng=Random.MersenneTwister(1)) == (-1.0, 1)
    @test is_feasible(sol, instance)
end

@testset "The candidate ratio must be below one" begin
    @test_throws ArgumentError AttractReduceMILPPerturbation(; min_candidate_ratio=1.0)
    @test_throws ArgumentError AttractReduceMILPPerturbation(; min_candidate_ratio=-0.1)
    @test AttractReduceMILPPerturbation(; min_candidate_ratio=0.0).min_candidate_ratio ==
        0.0
end

@testset "Pricing stops once the best count cannot be beaten" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    arc = hub_arc(instance, ("H", 1), ("D", 2))
    o1, o2 = hub_bundles(instance)
    full = TPO._attract_reduce_paths(sol, instance, arc, [o1, o2], Set([o2]))
    @test length(full) == 2
    early = TPO._attract_reduce_paths(sol, instance, arc, [o1, o2], Set([o2]); to_beat=2)
    @test isempty(early)
end

@testset "Pricing stops at the deadline" begin
    instance = hub_instance()
    sol = hub_solution(instance)
    sol0 = copy(sol)
    arc = hub_arc(instance, ("H", 1), ("D", 2))
    o1, o2 = hub_bundles(instance)
    late = TPO._attract_reduce_paths(
        sol, instance, arc, [o1, o2], Set([o2]); deadline=time() - 1.0
    )
    @test isempty(late)
    # A deadline far ahead prices every bundle.
    ahead = TPO._attract_reduce_paths(
        sol, instance, arc, [o1, o2], Set([o2]); deadline=time() + 3600.0
    )
    @test length(ahead) == 2
    @test TestFixtures.same_state(sol, sol0)
    # A call whose pricing deadline has passed prices nothing.
    p = AttractReduceMILPPerturbation(; time_limit=10.0)
    @test isnothing(
        TPO._select_attract_reduce_arc(
            sol, instance, p, Random.MersenneTwister(1); time_limit=-2.0
        ),
    )
    @test TestFixtures.same_state(sol, sol0)
    # The time already spent since the call start counts against the pricing deadline.
    @test isnothing(
        TPO._select_attract_reduce_arc(
            sol,
            instance,
            p,
            Random.MersenneTwister(1);
            start=time() - 10.0,
            time_limit=10.0,
        ),
    )
    @test TestFixtures.same_state(sol, sol0)
end

@testset "Pricing removes the bundle only with finite capacities" begin
    @test !TPO._has_finite_capacity(hub_instance())
    @test TPO._has_finite_capacity(hub_instance(; hub_capacity=7))
    # A -> M -> D carries the bundle, M -> D holds exactly its load. The path through N
    # shares M -> D, so it only fits once the bundle itself is out of the way.
    nodes = [Node(; id="A"), Node(; id="N"), Node(; id="M"), Node(; id="D")]
    arcs = [
        Arc(;
            origin_id="A", destination_id="M", cost=LinearArcCost(0.1), travel_time=Day(2)
        ),
        Arc(;
            origin_id="A", destination_id="N", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="N", destination_id="M", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="M",
            destination_id="D",
            cost=BinPackingArcCost(10.0, 10),
            travel_time=Day(1),
            capacity=5,
        ),
    ]
    commodity = Commodity(;
        origin_id="A",
        destination_id="D",
        quantity=1,
        departure_date=DateTime(2021, 1, 1),
        max_delivery_time=Day(3),
        size=5.0,
    )
    instance = Instance(nodes, arcs, [commodity], Day(1))
    sol = greedy_heuristic(instance; show_progress=false)
    sol0 = copy(sol)
    @test spatial_ids(instance, sol.bundle_paths[1]) == ["A", "M", "D"]
    arc = hub_arc(instance, ("N", 1), ("M", 2))
    price(; kwargs...) =
        TPO._attract_reduce_paths(sol, instance, arc, [1], Set{Int}(); kwargs...)
    @test isempty(price(; remove_bundle=false))
    @test TestFixtures.same_state(sol, sol0)
    paths = price(; remove_bundle=true)
    @test spatial_ids(instance, paths[1]) == ["A", "N", "M", "D"]
    @test TestFixtures.same_state(sol, sol0)
    @test price() == paths
    @test TestFixtures.same_state(sol, sol0)
end

@testset "An attract path through a full arc is still generated" begin
    # H -> D (capacity 7) already carries O2, O1 does not fit next to it but may swap in.
    instance = hub_instance(; hub_capacity=7)
    sol = hub_solution(instance)
    o1, o2 = hub_bundles(instance)
    arc = hub_arc(instance, ("H", 1), ("D", 2))
    paths = TPO._attract_reduce_paths(sol, instance, arc, [o1], Set{Int}())
    @test spatial_ids(instance, paths[o1]) == ["O1", "H", "D"]
end

@testset "Attract reduce model enforces the arc capacity" begin
    instance = hub_instance(; hub_capacity=7)
    sol = greedy_heuristic(instance; show_progress=false)
    modeled = [1, 2]
    new_paths = Dict(
        b => hub_path(instance, instance.bundles[b].origin_id, true) for b in modeled
    )
    p = AttractReduceMILPPerturbation(; time_limit=10.0)
    model, z = TPO._attract_reduce_model(p, sol, instance, modeled, new_paths)
    JuMP.optimize!(model)
    # Both on the hub costs 12 but needs 10 > 7, one alone costs 11 against 10.
    @test JuMP.value.(z) ≈ [0.0, 0.0]
end

@testset "Attract reduce on a benchmark instance" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    before = cost(sol)
    p = AttractReduceMILPPerturbation(; time_limit=10.0)
    (inc, n) = perturbate!(sol, instance, p; rng=Random.MersenneTwister(1))
    @test cost(sol) - before ≈ inc
    @test inc <= p.tolerance * before
    @test n >= 0
    @test is_feasible(sol, instance)
    @test elementary_paths(sol, instance)
end

@testset "Attract reduce rejects multimodal arcs" begin
    instance = TestFixtures._leg_instance([(10.0, 1, 10), (5.0, 1, 10)], 1)
    sol = greedy_heuristic(instance; show_progress=false)
    @test_throws ArgumentError perturbate!(sol, instance, AttractReduceMILPPerturbation())
end

@testset "ILS with the MILP perturbation never ends worse" begin
    instance = TestFixtures.tiny_instance()
    sol = TestFixtures.tiny_greedy()
    start_cost = cost(sol)
    result = iterated_local_search!(
        sol,
        instance,
        [
            ArcFlowMILPPerturbation(; time_limit=2.0),
            AttractReduceMILPPerturbation(; time_limit=2.0),
        ];
        config=ILSConfig(; time_limit=4, perturbation_time_limit=3, ls_time_limit=1),
        rng=Random.MersenneTwister(5),
        verbose=false,
    )
    @test result.best_cost <= start_cost + 1e-6
    @test cost(sol) <= start_cost + 1e-6
    @test is_feasible(sol, instance)
end
