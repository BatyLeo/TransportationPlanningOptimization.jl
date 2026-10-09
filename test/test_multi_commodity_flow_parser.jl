using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.MultiCommodityFlow
using Graphs
using Test
using Logging

# 3 nodes, two commodities.
# Commodity 1 (1 -> 3, demand 10): direct arc 1->3 is cheap per unit but has
# capacity 5 < demand, so it cannot carry the unsplittable commodity: the
# detour 1->2->3 must be used instead.
# Commodity 2 (2 -> 3, demand 5): shares arc 2->3 with the detour of commodity 1,
# so the fixed cost of that arc must be paid only once (network design version).
dow = """
MULTIGEN.DAT:
   3   3   2
   1   3   1   5   1   1   1
   1   2   3   100   10   1   2
   2   3   3   100   10   1   3
   1   3   10
   2   3   5
"""

@testset "Parsing emits no warning, such as the node_type deprecation" begin
    # Under --depwarn=yes a deprecation is a warning
    @test_logs min_level = Logging.Warn MultiCommodityFlow.parse_canad_instance(
        IOBuffer(dow)
    )
end

@testset "Tiny hand-written instance (network design)" begin
    instance = MultiCommodityFlow.parse_canad_instance(IOBuffer(dow); network_design=true)

    @test bundle_count(instance) == 2
    @test commodity_count(instance) == 2

    sol = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(sol, instance; verbose=true)
    # Commodity 1 detour: 10 * (3 + 3) variable + (10 + 10) fixed = 80.
    # Commodity 2 direct on 2->3 (already open): 5 * 3 variable = 15.
    # Total: 80 + 3 * 5 = 95.
    @test cost(sol) == 95.0
end

@testset "Tiny hand-written instance (UMCF)" begin
    instance = MultiCommodityFlow.parse_canad_instance(IOBuffer(dow))

    sol = greedy_heuristic(instance; show_progress=false)
    @test is_feasible(sol, instance; verbose=true)
    # No fixed cost: commodity 1 still needs the detour (capacity 5 < demand 10 on the
    # direct arc), commodity 2 stays direct.
    # Total variable cost only:
    # 10 * (3 + 3) + 5 * 3 = 60 + 15 = 75.
    @test cost(sol) == 75.0
end

@testset "Canad C c33" begin
    withenv("DATADEPS_ALWAYS_ACCEPT" => "true") do
        instance = load_instance(CanadC(), "c33"; network_design=true)

        @test Graphs.nv(instance.network_graph.graph) == 52
        @test Graphs.ne(instance.network_graph.graph) == 260
        @test commodity_count(instance) == 39

        sol = greedy_heuristic(instance; show_progress=false)
        @test is_feasible(sol, instance; verbose=true)
        @test cost(sol) >= 423_933

        umcf_instance = load_instance(CanadC(), "c33")
        umcf_sol = greedy_heuristic(umcf_instance; show_progress=false)
        @test is_feasible(umcf_sol, umcf_instance)
        @test cost(umcf_sol) >= cost(lower_bound(umcf_instance; show_progress=false))
    end
end
