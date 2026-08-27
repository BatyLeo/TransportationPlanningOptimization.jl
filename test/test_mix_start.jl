using Test
using Dates
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

# Already in Main from runtests.jl, but be defensive in case the file is loaded
# standalone via include from the REPL.
isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "max_pack_size returns the largest single-commodity size" begin
    instance = TestFixtures.tiny_instance()

    for bundle in instance.bundles
        expected = maximum(c.size for order in bundle.orders for c in order.commodities)
        @test TPO.max_pack_size(bundle) == expected
    end

    # max_pack_size is at most total_size.
    for bundle in instance.bundles
        @test TPO.max_pack_size(bundle) <= TPO.total_size(bundle)
    end
end

@testset "mix_greedy_and_lower_bound returns three feasible solutions" begin
    instance = TestFixtures.tiny_instance()

    result = TPO.mix_greedy_and_lower_bound(instance)

    @test result isa NamedTuple
    @test haskey(result, :mixed)
    @test haskey(result, :greedy)
    @test haskey(result, :lower_bound)

    @test TPO.is_feasible(result.mixed, instance)
    @test TPO.is_feasible(result.greedy, instance)
    @test TPO.is_feasible(result.lower_bound, instance)

    @test isfinite(TPO.cost(result.mixed))
    @test isfinite(TPO.cost(result.greedy))
    @test isfinite(TPO.cost(result.lower_bound))

    for path in result.mixed.bundle_paths
        @test !isempty(path)
    end
end

@testset "mix_greedy_and_lower_bound reproduces standalone greedy and lower_bound" begin
    instance = TestFixtures.tiny_instance()

    result = TPO.mix_greedy_and_lower_bound(instance)
    standalone_greedy = TestFixtures.tiny_greedy()
    standalone_lb = TPO.lower_bound(instance)

    @test TPO.cost(result.greedy) ≈ TPO.cost(standalone_greedy) atol = 1e-6
    @test TPO.cost(result.lower_bound) ≈ TPO.cost(standalone_lb) atol = 1e-6
end

@testset "choose_best_feasible returns the min-cost feasible solution" begin
    instance = TestFixtures.tiny_instance()

    result = TPO.mix_greedy_and_lower_bound(instance)
    candidates = [result.mixed, result.greedy, result.lower_bound]
    chosen = TPO.choose_best_feasible(candidates, instance)

    @test TPO.is_feasible(chosen, instance)
    @test TPO.cost(chosen) <=
        minimum(TPO.cost(s) for s in candidates if TPO.is_feasible(s, instance))
end

@testset "choose_best_feasible errors when no candidate is feasible" begin
    instance = TestFixtures.tiny_instance()

    empty_sol = TPO.Solution(instance)  # all empty paths, infeasible
    @test_throws ArgumentError TPO.choose_best_feasible([empty_sol], instance)
end
