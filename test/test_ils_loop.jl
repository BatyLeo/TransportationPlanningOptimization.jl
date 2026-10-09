using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

# A perturbation that never changes anything (used to exercise the
# no_change / max_no_change convergence path). It loops until the perturbation
# time limit, so tests must use a small `perturbation_time_limit`.
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

@testset "ILS never ends worse than the start" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    local_search!(sol, instance; time_limit=3.0)
    start_cost = cost(sol)

    result = iterated_local_search!(
        sol,
        instance,
        [DegradingPerturbation()];
        config=ILSConfig(;
            time_limit=5, perturbation_time_limit=0.2, ls_time_limit=1, max_no_change=1
        ),
        verbose=false,
    )

    @test result.improvement == 0.0 || result.best_cost <= start_cost + 1e-6
    @test is_feasible(sol, instance)
end

# Reports one changed bundle per call without touching the solution, and counts the calls.
# The infinite improvement ends the round after a single call (cost threshold reached).
struct CountingPerturbation <: AbstractPerturbation
    calls::Base.RefValue{Int}
end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::CountingPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    p.calls[] += 1
    return (Inf, 1)
end

@testset "ILS runs local search only once the accumulated change threshold is reached" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    perturbation = CountingPerturbation(Ref(0))

    # cost_update! runs once before the loop, then once after each local search phase
    calls_at_update = Int[]
    function record_update!(inst, s)
        push!(calls_at_update, perturbation.calls[])
        return nothing
    end

    result = iterated_local_search!(
        sol,
        instance,
        [perturbation];
        config=ILSConfig(;
            time_limit=30,
            perturbation_time_limit=1,
            ls_time_limit=1,
            change_threshold_ratio=3 / bundle_count(instance),
            max_no_improv=3,
        ),
        (cost_update!)=record_update!,
        rng=Random.MersenneTwister(1),
        verbose=false,
    )

    @test length(calls_at_update) >= 2
    @test calls_at_update[1] == 0
    @test calls_at_update == 3 .* (0:(length(calls_at_update) - 1))
    @test perturbation.calls[] == result.iterations
    @test is_feasible(sol, instance)
end
