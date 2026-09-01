using Test
using TransportationPlanningOptimization
using Dates
using MetaGraphsNext

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "lower_bound_incremental_cost equals classic for LinearArcCost" begin
    arc_f = LinearArcCost(2.0)
    C = LightCommodity{Nothing}
    new = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (3, 5, 7)
    ]
    @test TransportationPlanningOptimization.lower_bound_incremental_cost(
        arc_f, C[], new
    ) == TransportationPlanningOptimization.incremental_cost(arc_f, C[], new)
end

@testset "lower_bound_incremental_cost uses fractional bins" begin
    arc_f = BinPackingArcCost(10.0, 100)
    C = LightCommodity{Nothing}
    new = [
        LightCommodity(; origin_id="o", destination_id="d", size=Float64(s), info=nothing)
        for s in (60, 60)
    ]
    classic = TransportationPlanningOptimization.incremental_cost(arc_f, C[], new)
    lb = TransportationPlanningOptimization.lower_bound_incremental_cost(arc_f, C[], new)

    @test classic == 20.0
    @test isapprox(lb, 12.0; atol=1e-6)
    @test lb <= classic
end

@testset "update_bundle_cost_matrix! with cost_fn produces LB <= classic on BP arcs" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    empty_sol = Solution(instance)

    TransportationPlanningOptimization.update_bundle_cost_matrix!(empty_sol, instance, 1)
    classic_matrix = copy(instance.travel_time_graph.cost_matrix)

    TransportationPlanningOptimization.update_bundle_cost_matrix!(
        empty_sol,
        instance,
        1;
        cost_fn=TransportationPlanningOptimization.compute_ttg_edge_lower_bound_cost,
    )
    lb_matrix = instance.travel_time_graph.cost_matrix

    # All finite entries of LB matrix should be <= classic
    for i in axes(lb_matrix, 1), j in axes(lb_matrix, 2)
        c, l = classic_matrix[i, j], lb_matrix[i, j]
        if isfinite(c) && isfinite(l)
            @test l <= c + 1e-6
        end
    end
end

@testset "_direct_arc_order_lb_cost: BinPackingArcCost returns ceil bin count" begin
    cost = BinPackingArcCost(10.0, 100)
    f = TransportationPlanningOptimization._direct_arc_order_lb_cost
    @test f(cost, 0.0) == 0.0
    @test f(cost, 25.0) == 10.0
    @test f(cost, 100.0) == 10.0
    @test f(cost, 101.0) == 20.0
    @test f(cost, 250.0) == 30.0
end

@testset "_direct_arc_order_lb_cost: LinearArcCost is fractional" begin
    cost = LinearArcCost(2.0)
    f = TransportationPlanningOptimization._direct_arc_order_lb_cost
    @test f(cost, 0.0) == 0.0
    @test f(cost, 25.0) == 50.0
    @test f(cost, 0.5) == 1.0
end

@testset "compute_ttg_edge_lower_bound_cost uses per-order ceil on direct arc" begin
    # The "LB <= classic" invariant is already proved on `tiny` in the
    # "update_bundle_cost_matrix! ..." testset above, so `tiny` suffices here too.
    instance = TestFixtures.tiny_instance()
    empty_sol = Solution(instance)
    ttg = instance.travel_time_graph
    tsg = instance.time_space_graph

    # Find a bundle whose direct TTG edge exists. The direct arc is any TTG
    # edge whose spatial labels match (bundle.origin_id, bundle.destination_id)
    # (not necessarily the canonical (origin_codes[idx], destination_codes[idx])
    # pair, which sits at specific time-budget nodes that need not be adjacent).
    direct_idx = 0
    u_direct = 0
    v_direct = 0
    for idx in eachindex(instance.bundles)
        bundle = instance.bundles[idx]
        for (u, v) in ttg.bundle_arcs[idx]
            ul = MetaGraphsNext.label_for(ttg.graph, u)
            vl = MetaGraphsNext.label_for(ttg.graph, v)
            if ul[1] == bundle.origin_id && vl[1] == bundle.destination_id
                direct_idx = idx
                u_direct = u
                v_direct = v
                break
            end
        end
        direct_idx > 0 && break
    end
    @test direct_idx > 0
    bundle = instance.bundles[direct_idx]

    direct_cost = TransportationPlanningOptimization.compute_ttg_edge_lower_bound_cost(
        empty_sol, instance, bundle, u_direct, v_direct
    )

    # Hand-compute the expected per-order ceil bin cost plus node terms.
    expected = 0.0
    for order in bundle.orders
        u_tsg = TransportationPlanningOptimization.project_to_time_space_graph(
            u_direct, order, instance
        )
        v_tsg = TransportationPlanningOptimization.project_to_time_space_graph(
            v_direct, order, instance
        )
        u_label = MetaGraphsNext.label_for(tsg.graph, u_tsg)
        v_label = MetaGraphsNext.label_for(tsg.graph, v_tsg)
        arc = tsg.graph[u_label, v_label]
        order_size = sum(c.size for c in order.commodities; init=0.0)
        if arc.cost isa BinPackingArcCost
            expected += arc.cost.cost_per_bin * ceil(order_size / arc.cost.bin_capacity)
        elseif arc.cost isa LinearArcCost
            expected += arc.cost.cost_per_unit_size * order_size
        else
            expected += TransportationPlanningOptimization._direct_arc_order_lb_cost(
                arc, order_size, order.commodities, CheapestMode()
            )
        end
        # Destination-node cost charged once per order on the direct arc.
        dst_node = instance.network_graph.graph[v_label[1]]
        C = eltype(order.commodities)
        expected += TransportationPlanningOptimization.lower_bound_incremental_cost(
            dst_node.node_cost, C[], order.commodities
        )
    end

    @test isapprox(direct_cost, expected; atol=1e-6)
end
