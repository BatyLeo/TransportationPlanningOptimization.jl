using Test
using TransportationPlanningOptimization
using Dates
using MetaGraphsNext
using Graphs

const TPO = TransportationPlanningOptimization

@testset "IndexCache agrees with the MetaGraph" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    cache = instance.index_cache
    ng = instance.network_graph.graph
    ttg = instance.travel_time_graph.graph
    tsg = instance.time_space_graph.graph

    # ttg_code_to_spatial_code / ttg_code_to_tau
    for code in 1:Graphs.nv(ttg)
        loc, τ = MetaGraphsNext.label_for(ttg, code)
        @test cache.ttg_code_to_spatial_code[code] == MetaGraphsNext.code_for(ng, loc)
        @test cache.ttg_code_to_tau[code] == τ
    end

    # spatial_code_and_time_to_tsg_code / tsg_code_to_spatial_code
    for code in 1:Graphs.nv(tsg)
        nid, t = MetaGraphsNext.label_for(tsg, code)
        s = MetaGraphsNext.code_for(ng, nid)
        @test cache.tsg_code_to_spatial_code[code] == s
        @test cache.spatial_code_and_time_to_tsg_code[s, t] == code
    end

    # arc_of / node_cost_of: use === (identity, not equality) to verify the cache
    # stores the exact same object the MetaGraph holds, not a copy.
    for (u, v) in MetaGraphsNext.edge_labels(ng)
        su = MetaGraphsNext.code_for(ng, u)
        sv = MetaGraphsNext.code_for(ng, v)
        @test cache.spatial_pair_to_arc[(su, sv)] === ng[u, v]
    end

    for nid in MetaGraphsNext.labels(ng)
        c = MetaGraphsNext.code_for(ng, nid)
        @test cache.spatial_code_to_node_cost[c] === ng[nid].node_cost
    end
end

@testset "project_to_time_space_graph matches the label-based reference" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    ttg_struct = instance.travel_time_graph
    ttg = ttg_struct.graph
    tsg = instance.time_space_graph.graph
    H = instance.time_horizon_length
    arrival = TPO.is_date_arrival(ttg_struct)

    for (b_idx, bundle) in enumerate(instance.bundles)
        for order in bundle.orders
            for code in
                (ttg_struct.origin_codes[b_idx], ttg_struct.destination_codes[b_idx])
                loc, τ = MetaGraphsNext.label_for(ttg, code)
                t = arrival ? order.time_step - τ : order.time_step + τ
                if !(1 <= t <= H)
                    t = t > H ? t - H : t + H
                end
                ref = MetaGraphsNext.code_for(tsg, (loc, t))
                @test TPO.project_to_time_space_graph(code, order, instance) == ref
            end
        end
    end
end
