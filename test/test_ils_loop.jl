using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# A perturbation that never changes anything (used to exercise the
# no_change / max_no_change convergence path)
struct DegradingPerturbation <: AbstractPerturbation end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::DegradingPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    # No-op: doesn't change anything, so ILS will count it as no change
    return (0.0, 0)
end

@testset "ILS converges and returns ILSResult" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    start_cost = cost(sol)

    result = iterated_local_search!(
        sol,
        instance,
        [TestFixtures.ReinsertPerturbation()];
        config=ILSConfig(; time_limit=4, perturbation_time_limit=2, ls_time_limit=1),
        rng=Random.MersenneTwister(42),
        verbose=false,
    )

    @test result isa ILSResult
    @test result.improvement >= 0.0
    @test result.best_cost <= start_cost + 1e-6
    @test result.iterations >= 0
    @test result.time_elapsed > 0.0
    @test length(result.cost_history) >= 1
    @test result.cost_history[1] == (0.0, start_cost)
    @test is_feasible(sol, instance)
end

@testset "ILS with cost_update! callback" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()

    callback_count = Ref(0)
    function counting_update!(inst, s)
        callback_count[] += 1
        return nothing
    end

    result = iterated_local_search!(
        sol,
        instance,
        [TestFixtures.ReinsertPerturbation()];
        config=ILSConfig(; time_limit=4, perturbation_time_limit=2, ls_time_limit=1),
        (cost_update!)=counting_update!,
        rng=Random.MersenneTwister(42),
        verbose=false,
    )

    @test callback_count[] >= 1
    @test is_feasible(sol, instance)
end

@testset "ILS with on_improvement callback" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()

    improvements = Tuple{Float64,Float64}[]
    function track_improvement!(s, c, t)
        push!(improvements, (c, t))
        return nothing
    end

    result = iterated_local_search!(
        sol,
        instance,
        [TestFixtures.ReinsertPerturbation()];
        config=ILSConfig(; time_limit=4, perturbation_time_limit=2, ls_time_limit=1),
        on_improvement=track_improvement!,
        rng=Random.MersenneTwister(42),
        verbose=false,
    )

    # If there were improvements, the callback should have been called
    if result.improvement > 0.0
        @test length(improvements) >= 1
    end
    @test is_feasible(sol, instance)
end

@testset "ILS reverts on degradation" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    local_search!(sol, instance; time_limit=3.0)
    start_cost = cost(sol)

    result = iterated_local_search!(
        sol,
        instance,
        [DegradingPerturbation()];
        config=ILSConfig(; time_limit=5, max_no_change=1),
        verbose=false,
    )

    @test result.improvement == 0.0 || result.best_cost <= start_cost + 1e-6
    @test is_feasible(sol, instance)
end
