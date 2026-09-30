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
        cache.tsg_code_to_time[code] == last(MetaGraphsNext.label_for(tsg, code)) for
        code in 1:Graphs.nv(tsg)
    )
    # Single-mode legs: the one edge group is the leg itself.
    @test all(
        cache.edge_group_to_arc[(
            MetaGraphsNext.code_for(ng, u),
            MetaGraphsNext.code_for(ng, v),
            TPO._transit_key(
                TPO.travel_time_steps(ng[u, v]), cache.time_horizon_length, cache.wrap_time
            ),
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

# Both graphs store the arc of every edge, the cache must resolve each one from the codes.
_same_arc(a::MultiModalArc, b) = b isa MultiModalArc && a.modes == b.modes
_same_arc(a, b) = a === b

function _cache_matches_graphs(instance)
    cache = instance.index_cache
    ok = true
    for (graph, edge_arc) in (
        (instance.time_space_graph.graph, TPO.tsg_edge_arc),
        (instance.travel_time_graph.graph, TPO.ttg_edge_arc),
    )
        for (u, v) in MetaGraphsNext.edge_labels(graph)
            first(u) == first(v) && continue # shortcut
            arc = edge_arc(
                cache, MetaGraphsNext.code_for(graph, u), MetaGraphsNext.code_for(graph, v)
            )
            ok &= !isnothing(arc) && _same_arc(graph[u, v], arc)
        end
    end
    return ok
end

@testset "tsg_edge_arc and ttg_edge_arc match the graph edges (tiny)" begin
    @test _cache_matches_graphs(TestFixtures.tiny_instance())
end

for date_kw in (:departure_date, :arrival_date)
    @testset "tsg_edge_arc and ttg_edge_arc match the graph edges (mixed transit, wrap, $date_kw)" begin
        nodes = [
            NetworkNode(; id="A", node_type=:origin),
            NetworkNode(; id="B", node_type=:destination),
        ]
        # One singleton group (1 day) and one group of two modes (2 days).
        arcs = [
            Arc(;
                origin_id="A",
                destination_id="B",
                cost=LinearArcCost(10.0),
                travel_time=Day(1),
            ),
            Arc(;
                origin_id="A",
                destination_id="B",
                cost=LinearArcCost(5.0),
                travel_time=Day(2),
            ),
            Arc(;
                origin_id="A",
                destination_id="B",
                cost=LinearArcCost(6.0),
                travel_time=Day(2),
            ),
        ]
        # Two departure dates spread over the horizon, so that it exceeds every transit time.
        commodities = [
            Commodity(;
                origin_id="A",
                destination_id="B",
                quantity=1,
                date_kw => DateTime(2024, 1, d),
                max_delivery_time=Day(3),
                size=1.0,
            ) for d in (1, 6)
        ]
        instance = Instance(
            nodes, arcs, commodities, Day(1); allow_multimodal=true, wrap_time=true
        )
        tsg = instance.time_space_graph.graph
        @test any(e -> tsg[e...] isa MultiModalArc, MetaGraphsNext.edge_labels(tsg))
        @test any(e -> tsg[e...] isa NetworkArc, MetaGraphsNext.edge_labels(tsg))
        @test _cache_matches_graphs(instance)
    end
end
