using Test
using TransportationPlanningOptimization
using Dates
using MetaGraphsNext
using Graphs
using Random
isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

const TPO = TransportationPlanningOptimization

@testset "IndexCache agrees with the MetaGraph (tiny, exhaustive-as-aggregate)" begin
    instance = TestFixtures.tiny_instance()
    cache = instance.index_cache
    ng = instance.network_graph.graph
    ttg = instance.travel_time_graph.graph
    tsg = instance.time_space_graph.graph

    @test all(
        cache.ttg_code_to_spatial_code[code] ==
        MetaGraphsNext.code_for(ng, first(MetaGraphsNext.label_for(ttg, code))) &&
        cache.ttg_code_to_tau[code] == last(MetaGraphsNext.label_for(ttg, code)) for
        code in 1:Graphs.nv(ttg)
    )
    @test all(
        let (nid, t) = MetaGraphsNext.label_for(tsg, code),
            s = MetaGraphsNext.code_for(ng, nid)

            cache.tsg_code_to_spatial_code[code] == s &&
                cache.spatial_code_and_time_to_tsg_code[s, t] == code
        end for code in 1:Graphs.nv(tsg)
    )
    @test all(
        cache.spatial_pair_to_arc[(
            MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)
        )] === ng[u, v] for (u, v) in MetaGraphsNext.edge_labels(ng)
    )
    @test all(
        cache.spatial_code_to_node_cost[MetaGraphsNext.code_for(ng, nid)] ===
        ng[nid].node_cost for nid in MetaGraphsNext.labels(ng)
    )
end

@testset "IndexCache agrees at scale (small, sampled)" begin
    instance = TestFixtures.small_instance()
    cache = instance.index_cache
    ng = instance.network_graph.graph
    tsg = instance.time_space_graph.graph
    rng = MersenneTwister(0)
    for code in rand(rng, 1:Graphs.nv(tsg), 500)
        nid, t = MetaGraphsNext.label_for(tsg, code)
        s = MetaGraphsNext.code_for(ng, nid)
        @test cache.tsg_code_to_spatial_code[code] == s
        @test cache.spatial_code_and_time_to_tsg_code[s, t] == code
    end
end

@testset "project_to_time_space_graph matches the label-based reference (tiny)" begin
    instance = TestFixtures.tiny_instance()
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
