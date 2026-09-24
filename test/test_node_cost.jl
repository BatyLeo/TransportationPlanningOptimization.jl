using Test
using TransportationPlanningOptimization
using MetaGraphsNext
using Dates
using Random

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures
isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound: parse_inbound_instance

const TPO = TransportationPlanningOptimization

# A node cost with a fixed part, to exercise the non-linear (non-LinearNodeCost,
# non-NoNodeCost) dispatch path.
if !isdefined(Main, :FixedPlusLinearNodeCost)
    struct FixedPlusLinearNodeCost <: AbstractNodeCostFunction
        fixed::Float64
        per_unit::Float64
    end
    function TPO.evaluate(c::FixedPlusLinearNodeCost, comms::Vector{<:LightCommodity})
        return isempty(comms) ? 0.0 : c.fixed + c.per_unit * sum(x.size for x in comms)
    end
end

@testset "NoNodeCost evaluates to 0" begin
    C = LightCommodity{Nothing}
    items = [LightCommodity(; origin_id="o", destination_id="d", size=10.0, info=nothing)]
    @test TPO.evaluate(NoNodeCost(), items) == 0.0
    @test TPO.incremental_cost(NoNodeCost(), C[], items) == 0.0
    @test TPO.lower_bound_incremental_cost(NoNodeCost(), C[], items) == 0.0
end

@testset "NetworkNode defaults node_cost to NoNodeCost" begin
    n = NetworkNode(; id="A", node_type=:other)
    @test n.node_cost isa NoNodeCost
end

@testset "LinearNodeCost is linear in volume" begin
    C = LightCommodity{Nothing}
    items = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (10.0, 20.0)
    ]
    c = LinearNodeCost(3.0)
    @test isapprox(TPO.evaluate(c, items), 90.0; atol=1e-9)
    @test isapprox(TPO.incremental_cost(c, C[], items), 90.0; atol=1e-9)
end

# ── (a) Oracle: total_node_cost / cost(sol) agree with two independent brute-force
# computations, on greedy / local-search / ILS / removal checkpoints. ──────────────

# `evaluate(node_cost[head], collect(commodities on the assignment))` summed over
# every edge assignment.
function _node_oracle(sol, instance)
    cache = instance.index_cache
    return sum(
        TPO.evaluate(
            cache.spatial_code_to_node_cost[cache.tsg_code_to_spatial_code[edge[2]]],
            collect(commodities_of(a)),
        ) for (edge, a) in sol.assignments;
        init=0.0,
    )
end

# Independent oracle: walk each bundle's path edge by edge (no assignment lookup at
# all), summing `evaluate(node_cost[head], order.commodities)`. Exact for
# LinearNodeCost (additive across orders sharing an edge).
function _path_node_oracle(sol, instance)
    cache = instance.index_cache
    total = 0.0
    for (i, path) in enumerate(sol.bundle_paths)
        isempty(path) && continue
        bundle = instance.bundles[i]
        for order in bundle.orders
            for k in 1:(length(path) - 1)
                v_tsg = TPO.project_to_time_space_graph(path[k + 1], order, instance)
                sv = cache.tsg_code_to_spatial_code[v_tsg]
                total += TPO.evaluate(
                    cache.spatial_code_to_node_cost[sv], order.commodities
                )
            end
        end
    end
    return total
end

function _instance_with_node_cost(name::String)
    (; nodes, arcs, commodities) =
        name == "small" ? TestFixtures.small_parsed() : TestFixtures.tiny_parsed()
    nodes_with_cost = [
        NetworkNode(;
            id=n.id,
            node_type=n.node_type,
            capacity=n.capacity,
            info=n.info,
            node_cost=(n.node_type == :destination ? LinearNodeCost(1.0) : NoNodeCost()),
        ) for n in nodes
    ]
    return Instance(nodes_with_cost, arcs, commodities, Week(1); wrap_time=true)
end

function _check_node_cost_consistency(sol, instance)
    @test isapprox(total_node_cost(sol), _node_oracle(sol, instance); rtol=1e-9)
    @test isapprox(total_node_cost(sol), _path_node_oracle(sol, instance); rtol=1e-9)
    @test isapprox(cost(sol), total_arc_cost(sol) + total_node_cost(sol); rtol=1e-9)
end

@testset "Node cost oracle (tiny, small)" begin
    for name in ("tiny", "small")
        instance = _instance_with_node_cost(name)

        sol = greedy_heuristic(instance)
        _check_node_cost_consistency(sol, instance)
        name == "small" && @test total_node_cost(sol) > 0

        result = local_search!(sol, instance; max_iter=300, rng=MersenneTwister(1))
        @test isapprox(result.final_cost, cost(sol); rtol=1e-9)
        _check_node_cost_consistency(sol, instance)

        for i in eachindex(sol.bundle_paths)
            TPO.remove_bundle_path!(sol, instance, i)
        end
        @test isapprox(total_node_cost(sol), 0.0; atol=1e-6)
    end
end

# ── (b) Nonlinear node cost on a shared time-space arc. ─────────────────────────

function _nonlinear_shared_arc_instance()
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(;
            id="B", node_type=:other, node_cost=FixedPlusLinearNodeCost(100.0, 1.0)
        ),
        NetworkNode(; id="C", node_type=:destination),
        NetworkNode(; id="D", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="B", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="B", destination_id="D", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="C",
            size=2.0,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
        ),
        Commodity(;
            origin_id="A",
            destination_id="D",
            size=1.0,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
        ),
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

# Walk the TTG from `bundle_idx`'s origin through the given chain of spatial ids,
# returning the sequence of TTG node codes.
function _ttg_path(ttg, bundle_idx, ids...)
    codes = Int[]
    u = ttg.origin_codes[bundle_idx]
    push!(codes, u)
    for id in ids[2:end]
        v = only(
            v for (uu, v) in ttg.bundle_arcs[bundle_idx] if
            uu == u && MetaGraphsNext.label_for(ttg.graph, v)[1] == id
        )
        push!(codes, v)
        u = v
    end
    return codes
end

@testset "Nonlinear node cost on a shared time-space arc" begin
    instance = _nonlinear_shared_arc_instance()
    idx_c = findfirst(b -> b.destination_id == "C", instance.bundles)
    idx_d = findfirst(b -> b.destination_id == "D", instance.bundles)

    ttg = instance.travel_time_graph
    ab_edge_c = only(
        (u, v) for (u, v) in ttg.bundle_arcs[idx_c] if
        MetaGraphsNext.label_for(ttg.graph, u)[1] == "A" &&
        MetaGraphsNext.label_for(ttg.graph, v)[1] == "B"
    )

    sol = Solution(instance)
    inc = TPO.compute_ttg_edge_incremental_cost(
        sol, instance, instance.bundles[idx_c], ab_edge_c...
    )
    @test isapprox(inc, 122.0; atol=1e-9)

    path_c = _ttg_path(ttg, idx_c, "A", "B", "C")
    added_c = TPO.add_bundle_path!(sol, instance, idx_c, path_c)
    @test isapprox(added_c, 142.0; atol=1e-9)

    path_d = _ttg_path(ttg, idx_d, "A", "B", "D")
    lb_d = TPO.compute_ttg_edge_lower_bound_cost(
        sol, instance, instance.bundles[idx_d], path_d[1], path_d[2]
    )
    @test isapprox(lb_d, 11.0; atol=1e-9)
    inc_d = TPO.compute_ttg_edge_incremental_cost(
        sol, instance, instance.bundles[idx_d], path_d[1], path_d[2]
    )
    @test isapprox(inc_d, 11.0; atol=1e-9)

    added_d = TPO.add_bundle_path!(sol, instance, idx_d, path_d)
    @test isapprox(added_d, 21.0; atol=1e-9)

    @test isapprox(cost(sol), 163.0; atol=1e-9)
    @test isapprox(cost(Solution(sol.bundle_paths, instance)), 163.0; atol=1e-9)

    sol_greedy = greedy_heuristic(instance)
    @test isapprox(cost(sol_greedy), 163.0; atol=1e-9)

    removed_c = TPO.remove_bundle_path!(sol, instance, idx_c)
    @test isapprox(removed_c, -42.0; atol=1e-9)

    sol2 = Solution(instance)
    TPO.add_bundle_path!(sol2, instance, idx_c, _ttg_path(ttg, idx_c, "A", "B", "C"))
    TPO.add_bundle_path!(sol2, instance, idx_d, _ttg_path(ttg, idx_d, "A", "B", "D"))
    removed_d = TPO.remove_bundle_path!(sol2, instance, idx_d)
    @test isapprox(removed_d, -21.0; atol=1e-9)
    TPO.remove_bundle_path!(sol2, instance, idx_c)
    @test isapprox(total_node_cost(sol2), 0.0; atol=1e-9)
end

@testset "_direct_arc_lb_cost includes the destination node cost" begin
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination, node_cost=LinearNodeCost(5.0)),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(2.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=3.0,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))
    ttg = instance.travel_time_graph
    lb = TPO._direct_arc_lb_cost(
        instance.bundles[1],
        instance,
        ttg.origin_codes[1],
        ttg.destination_codes[1],
        CheapestMode(),
    )
    @test isapprox(lb, 2.0 * 3.0 + 5.0 * 3.0; atol=1e-9)  # arc part + node part (both linear)
end

# ── (c) Acceptance: cost(sol) and _try_reinsert_bundle! must see the node cost. ──

function _through_node_instance()
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="H", node_type=:other, node_cost=LinearNodeCost(100.0)),
        NetworkNode(; id="C", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="H", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="H", destination_id="C", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="C",
            size=1.0,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
        ),
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

@testset "Acceptance sees node cost (_try_reinsert_bundle!, choose_best_feasible)" begin
    instance = _through_node_instance()
    ttg = instance.travel_time_graph
    path = _ttg_path(ttg, 1, "A", "H", "C")
    @test path[end] == ttg.destination_codes[1]

    sol = Solution(instance)
    TPO.add_bundle_path!(sol, instance, 1, path)
    @test is_feasible(sol, instance)
    @test isapprox(cost(sol), 102.0; atol=1e-9)

    improvement = TPO._try_reinsert_bundle!(sol, instance, 1, CheapestMode())
    @test isapprox(improvement, 92.0; atol=1e-9)
    @test isapprox(cost(sol), 10.0; atol=1e-9)

    sol_via_h = Solution(instance)
    TPO.add_bundle_path!(sol_via_h, instance, 1, _ttg_path(ttg, 1, "A", "H", "C"))
    chosen = TPO.choose_best_feasible([sol_via_h, greedy_heuristic(instance)], instance)
    @test isapprox(cost(chosen), 10.0; atol=1e-9)
end

# ── (d) Slope scaling scales the arc part only. ─────────────────────────────────

@testset "Slope scaling does not scale node costs" begin
    instance = _through_node_instance()
    ttg = instance.travel_time_graph
    ng = instance.network_graph.graph
    a_code = MetaGraphsNext.code_for(ng, "A")
    h_code = MetaGraphsNext.code_for(ng, "H")
    ttg.cost_scaling[(a_code, h_code)] = 2.0

    sol = Solution(instance)
    ah_edge = only(
        (u, v) for
        (u, v) in ttg.bundle_arcs[1] if MetaGraphsNext.label_for(ttg.graph, u)[1] == "A" &&
        MetaGraphsNext.label_for(ttg.graph, v)[1] == "H"
    )
    inc = TPO.compute_ttg_edge_incremental_cost(
        sol, instance, instance.bundles[1], ah_edge...
    )
    @test isapprox(inc, 2 * 1 + 100; atol=1e-9)

    empty!(ttg.cost_scaling)
end

# ── (e) MultiAssignment: node cost charged once across modes. ──────────────────

function _multimodal_node_cost_network()
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(;
            id="B", node_type=:other, node_cost=FixedPlusLinearNodeCost(100.0, 1.0)
        ),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=1,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=100,
        ),
    ]
    return nodes, arcs
end

@testset "MultiAssignment node cost (FillThenSpillMode)" begin
    nodes, arcs = _multimodal_node_cost_network()
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            quantity=3,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode())
    @test is_feasible(sol, instance)

    assignment = only(values(sol.assignments))
    @test assignment isa TPO.MultiAssignment
    @test isapprox(arc_cost_of(assignment), 11.0; atol=1e-9)  # 1*1 + 2*5
    @test isapprox(node_cost_of(assignment), 103.0; atol=1e-9)  # 100 + 1*3
    @test isapprox(cost_of(assignment), 114.0; atol=1e-9)

    removed = TPO.remove_bundle_path!(sol, instance, 1)
    @test isapprox(removed, -114.0; atol=1e-9)
    @test isapprox(node_cost_of(assignment), 0.0; atol=1e-9)
end

@testset "MultiAssignment node cost (CheapestMode, once across modes)" begin
    nodes, arcs = _multimodal_node_cost_network()
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            info=1,
        ),
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=2.0,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            info=2,
        ),
    ]
    instance = Instance(
        nodes, arcs, commodities, Day(1); allow_multimodal=true, group_by=c -> c.info
    )
    idx_small = findfirst(b -> isapprox(total_size(b), 1.0), instance.bundles)
    idx_large = findfirst(b -> isapprox(total_size(b), 2.0), instance.bundles)

    sol = Solution(instance)
    TPO.insert_bundle!(sol, instance, idx_small)  # fills the cap-1 cheap mode
    TPO.insert_bundle!(sol, instance, idx_large)  # cap-1 full -> spills to cap-100
    @test is_feasible(sol, instance)

    assignment = only(values(sol.assignments))
    @test isapprox(node_cost_of(assignment), 103.0; atol=1e-9)  # 100 + 1*3, once
end

# ── (e2) Snapshot / restore on a multi-modal, node-costed edge is a full round trip. ──

@testset "Snapshot/restore preserves node cost on a multi-modal edge" begin
    nodes, arcs = _multimodal_node_cost_network()
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            quantity=3,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode())
    edge = only(keys(sol.assignments))
    assignment = sol.assignments[edge]

    before_arc = arc_cost_of(assignment)
    before_node = node_cost_of(assignment)
    before_cost = cost_of(assignment)

    snap = TPO._snapshot_assignment(assignment)
    assignment.node_cost = 999.0
    assignment.per_mode[1].arc_cost = 999.0
    TPO._restore_assignment!(assignment, snap)

    @test arc_cost_of(assignment) == before_arc
    @test node_cost_of(assignment) == before_node
    @test cost_of(assignment) == before_cost
end

# ── Instance construction rejects a node cost that is nonzero on an empty load. ──

@testset "Node cost must evaluate to 0 on an empty load" begin
    struct _BrokenNodeCost <: AbstractNodeCostFunction end
    TPO.evaluate(::_BrokenNodeCost, ::Vector{<:LightCommodity}) = 1.0

    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination, node_cost=_BrokenNodeCost()),
    ]
    arcs = [
        Arc(;
            origin_id="A", destination_id="B", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            size=1.0,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
        ),
    ]
    @test_throws ArgumentError Instance(nodes, arcs, commodities, Day(1))
end

# ── (f) Hot-path guard: NoNodeCost/LinearNodeCost fast paths allocate nothing. ──
# Wrapped in a function: `@allocated` at testset top level would otherwise also
# measure global-variable access and first-call compilation.

function _alloc_refresh_node_cost!(a, node_f)
    TPO._refresh_node_cost!(a, node_f) # warm-up (triggers compilation)
    return @allocated TPO._refresh_node_cost!(a, node_f)
end

function _alloc_node_incremental_cost(node_f, existing, comms, s)
    TPO._node_incremental_cost(node_f, existing, comms, s) # warm-up
    return @allocated TPO._node_incremental_cost(node_f, existing, comms, s)
end

function _alloc_node_lower_bound_incremental_cost(node_f, existing, comms)
    TPO._node_lower_bound_incremental_cost(node_f, existing, comms) # warm-up
    return @allocated TPO._node_lower_bound_incremental_cost(node_f, existing, comms)
end

@testset "NoNodeCost/LinearNodeCost fast paths allocate nothing" begin
    C = LightCommodity{Nothing}
    comms = [LightCommodity(; origin_id="o", destination_id="d", size=1.0, info=nothing)]

    single = TPO.SingleAssignment{C}()
    @test _alloc_refresh_node_cost!(single, LinearNodeCost(1.0)) == 0
    @test _alloc_node_incremental_cost(LinearNodeCost(1.0), nothing, comms, 1.0) == 0

    @test _alloc_node_incremental_cost(NoNodeCost(), nothing, comms, 1.0) == 0
    @test _alloc_refresh_node_cost!(single, NoNodeCost()) == 0
    @test _alloc_node_lower_bound_incremental_cost(LinearNodeCost(1.0), single, comms) == 0
end
