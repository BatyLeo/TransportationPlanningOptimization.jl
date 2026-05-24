using Test
using TransportationPlanningOptimization
using MetaGraphsNext

const TPO = TransportationPlanningOptimization

@testset "NoNodeCost evaluates to 0" begin
    C = LightCommodity{true,Nothing}
    items = [
        LightCommodity(;
            origin_id="o", destination_id="d", size=10.0, info=nothing, is_date_arrival=true
        ),
    ]
    @test TPO.evaluate(NoNodeCost(), items) == 0.0
    @test TPO.incremental_cost(NoNodeCost(), C[], items) == 0.0
    @test TPO.lower_bound_incremental_cost(NoNodeCost(), C[], items) == 0.0
end

@testset "NetworkNode defaults node_cost to NoNodeCost" begin
    n = NetworkNode(; id="A", node_type=:other)
    @test n.node_cost isa NoNodeCost
end

using Dates

# Local node-cost subtype for testing the integration. Mirrors the shape that
# Inbound's NodeVolumeCost will take in Task 6.
struct _TestNodeCost <: AbstractNodeCostFunction
    factor::Float64
end
TPO.evaluate(c::_TestNodeCost, comms) = c.factor * sum(x.size for x in comms; init=0.0)
function TPO.incremental_cost(c::_TestNodeCost, _, new)
    return c.factor * sum(x.size for x in new; init=0.0)
end
function TPO.lower_bound_incremental_cost(c::_TestNodeCost, e, n)
    return TPO.incremental_cost(c, e, n)
end

@testset "compute_ttg_edge_* adds destination node cost" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )

    # Inject a non-trivial node cost on every destination node.
    nodes_with_cost = [
        NetworkNode(;
            id=n.id,
            node_type=n.node_type,
            cost=n.cost,
            capacity=n.capacity,
            info=n.info,
            node_cost=(n.node_type == :destination ? _TestNodeCost(1.0) : NoNodeCost()),
        ) for n in nodes
    ]

    instance_plain = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    instance_with_cost = Instance(
        nodes_with_cost, arcs, commodities, Week(1); wrap_time=true
    )

    # Pick one bundle and a TTG arc whose spatial destination is a `:destination`
    # node. Each bundle's last (non-shortcut) arc lands on its destination node.
    bundle = instance_plain.bundles[1]
    ttg = instance_plain.travel_time_graph

    # Find a TTG edge whose spatial destination is `bundle.destination_id`
    # (i.e. a `:destination` spatial node).
    target_edge = nothing
    for (u_code, v_code) in ttg.bundle_arcs[1]
        u_label = MetaGraphsNext.label_for(ttg.graph, u_code)
        v_label = MetaGraphsNext.label_for(ttg.graph, v_code)
        if v_label[1] == bundle.destination_id && u_label[1] != v_label[1]
            target_edge = (u_code, v_code)
            break
        end
    end
    @test target_edge !== nothing
    u_code, v_code = target_edge

    sol_plain = Solution(instance_plain)
    sol_with_cost = Solution(instance_with_cost)
    bundle_with_cost = instance_with_cost.bundles[1]

    inc_plain = TPO.compute_ttg_edge_incremental_cost(
        sol_plain, instance_plain, bundle, u_code, v_code
    )
    inc_with_cost = TPO.compute_ttg_edge_incremental_cost(
        sol_with_cost, instance_with_cost, bundle_with_cost, u_code, v_code
    )
    @test inc_with_cost > inc_plain + 1e-6

    lb_plain = TPO.compute_ttg_edge_lower_bound_cost(
        sol_plain, instance_plain, bundle, u_code, v_code
    )
    lb_with_cost = TPO.compute_ttg_edge_lower_bound_cost(
        sol_with_cost, instance_with_cost, bundle_with_cost, u_code, v_code
    )
    @test lb_with_cost > lb_plain + 1e-6

    # Direct-arc path: from bundle.origin_id to bundle.destination_id.
    direct_edge = nothing
    for (uc, vc) in ttg.bundle_arcs[1]
        ul = MetaGraphsNext.label_for(ttg.graph, uc)
        vl = MetaGraphsNext.label_for(ttg.graph, vc)
        if ul[1] == bundle.origin_id && vl[1] == bundle.destination_id
            direct_edge = (uc, vc)
            break
        end
    end
    if direct_edge !== nothing
        uc, vc = direct_edge
        d_plain = TPO.compute_ttg_edge_lower_bound_cost(
            sol_plain, instance_plain, bundle, uc, vc
        )
        d_with_cost = TPO.compute_ttg_edge_lower_bound_cost(
            sol_with_cost, instance_with_cost, bundle_with_cost, uc, vc
        )
        @test d_with_cost > d_plain + 1e-6
    end
end
