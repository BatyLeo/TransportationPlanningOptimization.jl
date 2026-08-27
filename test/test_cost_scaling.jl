using Test
using TransportationPlanningOptimization
using Dates
isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

const TPO = TransportationPlanningOptimization

@testset "TravelTimeGraph has cost_scaling field" begin
    instance = TestFixtures.tiny_instance()
    TestFixtures.reset!()  # start from a clean scaling dict
    ttg = instance.travel_time_graph
    @test hasproperty(ttg, :cost_scaling)
    @test ttg.cost_scaling isa Dict{Tuple{Int,Int},Float64}
    @test isempty(ttg.cost_scaling)
end

@testset "cost_scaling multiplies edge cost" begin
    instance = TestFixtures.tiny_instance()
    TestFixtures.reset!()  # start from a clean scaling dict
    sol = Solution(instance)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    bundle = instance.bundles[1]

    # Pick the first usable arc for bundle 1 (skip self-loops)
    (u, v) = ttg.bundle_arcs[1][1]
    if cache.ttg_code_to_spatial_code[u] == cache.ttg_code_to_spatial_code[v]
        (u, v) = ttg.bundle_arcs[1][2]
    end

    # Compute baseline cost (no scaling)
    baseline = TPO.compute_ttg_edge_incremental_cost(sol, instance, bundle, u, v)

    # Set scaling factor = 2.0 on the spatial arc
    su = cache.ttg_code_to_spatial_code[u]
    sv = cache.ttg_code_to_spatial_code[v]
    ttg.cost_scaling[(su, sv)] = 2.0

    scaled = TPO.compute_ttg_edge_incremental_cost(sol, instance, bundle, u, v)
    @test scaled ≈ 2.0 * baseline atol = 1e-6

    # Clear scaling and verify it reverts
    empty!(ttg.cost_scaling)
    reset = TPO.compute_ttg_edge_incremental_cost(sol, instance, bundle, u, v)
    @test reset ≈ baseline atol = 1e-6
end
