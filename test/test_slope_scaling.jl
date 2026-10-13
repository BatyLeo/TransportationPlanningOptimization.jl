using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "slope_scaling_update! populates cost_scaling" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()

    @test isempty(instance.travel_time_graph.cost_scaling)
    slope_scaling_update!(instance, sol)
    @test !isempty(instance.travel_time_graph.cost_scaling)
end

@testset "slope_scaling_update! factors are between 1 and 2" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    slope_scaling_update!(instance, sol)

    for factor in values(instance.travel_time_graph.cost_scaling)
        @test 1.0 <= factor <= 2.0
    end
end

@testset "slope_scaling_update! on empty solution leaves cost_scaling empty" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = SolutionState(instance)
    slope_scaling_update!(instance, sol)
    @test isempty(instance.travel_time_graph.cost_scaling)
end

@testset "slope_scaling_update! excludes factors of exactly 1.0" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    slope_scaling_update!(instance, sol)

    for factor in values(instance.travel_time_graph.cost_scaling)
        @test !isapprox(factor, 1.0; atol=1e-9)
    end
end

@testset "slope_scaling_update! clears stale entries between calls" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    slope_scaling_update!(instance, sol)
    @test !isempty(instance.travel_time_graph.cost_scaling)

    empty_sol = SolutionState(instance)
    slope_scaling_update!(instance, empty_sol)
    @test isempty(instance.travel_time_graph.cost_scaling)
end

# Two time-space edges of one group, with 4 bins holding 2.4 capacities (factor 4/3)
# and 3 bins holding 1.8 capacities (factor 1.5).
# Needs a `wrap_time=true` instance (the shifted edge must keep the same edge group).
function _two_edge_group_solution(instance, greedy)
    cache = instance.index_cache
    (u1, v1), template = first(
        (e, a) for (e, a) in greedy.assignments if a isa TPO.SingleAssignment &&
            !isnothing(TPO._bin_packing_cost_of(TPO.tsg_edge_arc(cache, e...).cost)) &&
            !isempty(a.commodities)
    )
    key = TPO.tsg_edge_key(cache, u1, v1)
    capacity = TPO._bin_packing_cost_of(TPO.tsg_edge_arc(cache, u1, v1).cost).bin_capacity
    shift(u) = cache.spatial_code_and_time_to_tsg_code[
        cache.tsg_code_to_spatial_code[u],
        mod1(cache.tsg_code_to_time[u] + 1, cache.time_horizon_length),
    ]
    (u2, v2) = (shift(u1), shift(v1))
    @assert u2 != 0 &&
        v2 != 0 &&
        (u2, v2) != (u1, v1) &&
        TPO.tsg_edge_key(cache, u2, v2) == key
    c = first(template.commodities)
    function assignment(n_bins, size)
        commodities = [
            TPO.LightCommodity(c.origin_id, c.destination_id, size * capacity, c.info) for
            _ in 1:n_bins
        ]
        bins = [TPO.Bin([x], capacity - x.size) for x in commodities]
        return TPO.SingleAssignment{typeof(c)}(commodities, bins, 0.0)
    end
    return key, (u1, v1) => assignment(4, 0.6), (u2, v2) => assignment(3, 0.6)
end

@testset "slope_scaling_update! takes the largest factor of a group" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    greedy = TestFixtures.small_greedy()
    key, edge1, edge2 = _two_edge_group_solution(instance, greedy)
    for (a1, a2) in ((edge1.second, edge2.second), (edge2.second, edge1.second))
        sol = SolutionState(instance)
        sol.assignments[edge1.first] = a1
        sol.assignments[edge2.first] = a2
        slope_scaling_update!(instance, sol)
        @test instance.travel_time_graph.cost_scaling[key] == 1.5
    end

    sol = SolutionState(instance)
    sol.assignments[edge1.first] = edge1.second
    slope_scaling_update!(instance, sol)
    @test instance.travel_time_graph.cost_scaling[key] == 4 / 3
    TestFixtures.reset!()
end

@testset "slope_scaling_update! does not accumulate across calls" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    greedy = TestFixtures.small_greedy()
    key, edge1, edge2 = _two_edge_group_solution(instance, greedy)
    sol = SolutionState(instance)
    sol.assignments[edge1.first] = edge1.second
    sol.assignments[edge2.first] = edge2.second
    slope_scaling_update!(instance, sol)
    @test instance.travel_time_graph.cost_scaling[key] == 1.5

    delete!(sol.assignments, edge2.first)
    slope_scaling_update!(instance, sol)
    @test instance.travel_time_graph.cost_scaling[key] == 4 / 3
    TestFixtures.reset!()
end

@testset "slope scaling does not change insertions or local search" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    base = greedy_heuristic(instance; show_progress=false)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    factors = Random.MersenneTwister(7)
    for arcs in ttg.bundle_arcs, (u, v) in arcs
        ttg.cost_scaling[TPO.ttg_edge_key(cache, u, v)] = 1 + 2 * rand(factors)
    end

    scaled = greedy_heuristic(instance; show_progress=false)
    @test scaled.bundle_paths == base.bundle_paths
    @test cost(scaled) == cost(base)

    local_search_run(sol) = local_search!(
        sol, instance; time_limit=600, max_iter=300, rng=Random.MersenneTwister(1)
    )
    ls_scaled = deepcopy(base)
    local_search_run(ls_scaled)
    TestFixtures.reset!()
    ls_plain = deepcopy(base)
    local_search_run(ls_plain)
    @test ls_scaled.bundle_paths == ls_plain.bundle_paths
    @test cost(ls_scaled) == cost(ls_plain)
end

@testset "iterated_local_search! resets the slope scaling" begin
    instance = TestFixtures.small_instance()
    TestFixtures.reset!()
    sol = TestFixtures.small_greedy()
    config = ILSConfig(; time_limit=3, perturbation_time_limit=1, ls_time_limit=1)
    scaling_was_set = Ref(false)
    function recording_update!(inst, s)
        slope_scaling_update!(inst, s)
        scaling_was_set[] |= !isempty(inst.travel_time_graph.cost_scaling)
        return nothing
    end
    iterated_local_search!(
        sol,
        instance,
        [TestFixtures.ReinsertPerturbation()];
        config,
        (cost_update!)=recording_update!,
        rng=Random.MersenneTwister(42),
        verbose=false,
    )
    @test scaling_was_set[]
    @test isempty(instance.travel_time_graph.cost_scaling)

    function failing_update!(inst, s)
        slope_scaling_update!(inst, s)
        @test !isempty(inst.travel_time_graph.cost_scaling)
        return error("boom")
    end
    @test_throws ErrorException iterated_local_search!(
        TestFixtures.small_greedy(),
        instance,
        [TestFixtures.ReinsertPerturbation()];
        config,
        (cost_update!)=failing_update!,
        verbose=false,
    )
    @test isempty(instance.travel_time_graph.cost_scaling)
end
