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
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
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
# The infinite cost increase ends the round after a single call (cost threshold reached).
struct CountingPerturbation <: AbstractPerturbation
    calls::Base.RefValue{Int}
end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::CountingPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
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

# Reports a cost increase of a fixed fraction of the current cost and no changed bundle.
struct FixedIncreasePerturbation <: AbstractPerturbation
    calls::Base.RefValue{Int}
    fraction::Float64
end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::FixedIncreasePerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    p.calls[] += 1
    return (p.fraction * cost(sol), 0)
end

@testset "ILS cost threshold only counts cost increases" begin
    instance = TestFixtures.small_instance()

    # A cheaper perturbation never reaches the cost threshold, so the phase runs until its
    # time limit
    sol = TestFixtures.small_greedy()
    cheaper = FixedIncreasePerturbation(Ref(0), -0.6)
    result = iterated_local_search!(
        sol,
        instance,
        [cheaper];
        config=ILSConfig(;
            time_limit=5, perturbation_time_limit=0.05, ls_time_limit=1, max_no_change=1
        ),
        rng=Random.MersenneTwister(1),
        verbose=false,
    )
    @test result.iterations == 1
    @test cheaper.calls[] > 1

    # A large cost increase ends the phase after a single call
    sol = TestFixtures.small_greedy()
    costlier = FixedIncreasePerturbation(Ref(0), 0.6)
    result = iterated_local_search!(
        sol,
        instance,
        [costlier];
        config=ILSConfig(;
            time_limit=5,
            perturbation_time_limit=0.05,
            ls_time_limit=1,
            cost_threshold_ratio=0.5,
            max_no_change=1,
        ),
        rng=Random.MersenneTwister(1),
        verbose=false,
    )
    @test result.iterations == 1
    @test costlier.calls[] == 1
end

# Lowers the cost on its first call (by a local search) without counting any changed bundle,
# so the change threshold is never reached and the loop runs no local search.
struct SilentImprovePerturbation <: AbstractPerturbation
    lowered_cost::Base.RefValue{Float64}
end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::SilentImprovePerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    isnan(p.lowered_cost[]) || return (0.0, 0)
    before = cost(sol)
    local_search!(sol, instance; time_limit=2.0, rng)
    p.lowered_cost[] = cost(sol)
    return (p.lowered_cost[] - before, 0)
end

@testset "ILS keeps an improvement found by a perturbation without local search" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    start_cost = cost(sol)
    perturbation = SilentImprovePerturbation(Ref(NaN))

    result = iterated_local_search!(
        sol,
        instance,
        [perturbation];
        config=ILSConfig(;
            time_limit=10,
            perturbation_time_limit=1,
            ls_time_limit=0,
            final_ls_time_limit=0,
            max_no_change=1,
        ),
        rng=Random.MersenneTwister(1),
        verbose=false,
    )

    @test perturbation.lowered_cost[] < start_cost
    # The lowered cost was recorded as a best right after the phase.
    @test result.cost_history[2][2] == perturbation.lowered_cost[]
    # The final local search has no time, so the lowered solution is returned as is.
    @test result.best_cost ≈ perturbation.lowered_cost[]
    @test cost(sol) ≈ perturbation.lowered_cost[]
    @test is_feasible(sol, instance)
end

# Records the time budget of every call.
struct TimeRecordingPerturbation <: AbstractPerturbation
    calls::Vector{Tuple{Float64,Float64}}
end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::TimeRecordingPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    push!(p.calls, (time(), time_limit))
    sleep(0.01)
    return (0.0, 0)
end

@testset "Perturbations receive the time left in the loop and in the phase" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    perturbation = TimeRecordingPerturbation(Tuple{Float64,Float64}[])

    iterated_local_search!(
        sol,
        instance,
        [perturbation];
        config=ILSConfig(;
            time_limit=1.2,
            perturbation_time_limit=0.5,
            ls_time_limit=1,
            final_ls_time_limit=0,
            max_no_change=100,
        ),
        rng=Random.MersenneTwister(1),
        verbose=false,
    )

    @test length(perturbation.calls) > 2
    @test all(c -> 0 < c[2] <= 0.5, perturbation.calls)
    # No call is allowed to run past the end of the main loop (1.2 s is not a multiple of
    # the phase limit, so the last phase is cut short by the loop and not by the phase
    # limit).
    @test all(c -> c[1] + c[2] <= perturbation.calls[1][1] + 1.2 + 0.05, perturbation.calls)
    # The budget shrinks within the first phase.
    @test perturbation.calls[2][2] < perturbation.calls[1][2]
end

# Returns at once when it gets less than a second, as the MILP perturbations do.
struct ShortBudgetPerturbation <: AbstractPerturbation
    budgets::Vector{Float64}
end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::ShortBudgetPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    push!(p.budgets, time_limit)
    time_limit >= 1.0 && sleep(0.2)
    return (0.0, 0)
end

@testset "No perturbation call starts with less than a second left" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    p = ShortBudgetPerturbation(Float64[])
    iterated_local_search!(
        sol,
        instance,
        [p];
        config=ILSConfig(;
            time_limit=5, perturbation_time_limit=3, ls_time_limit=1, max_no_change=100
        ),
        rng=Random.MersenneTwister(1),
        verbose=false,
    )
    @test !isempty(p.budgets)
    @test all(isfinite, p.budgets)
    @test all(>=(1.0), p.budgets)
    @test length(p.budgets) < 50
end

@testset "ILSConfig rejects invalid time limits" begin
    @test_throws ArgumentError ILSConfig(; time_limit=-1)
    @test_throws ArgumentError ILSConfig(; perturbation_time_limit=0)
    @test_throws ArgumentError ILSConfig(; ls_time_limit=-1)
    @test ILSConfig(; time_limit=0, ls_time_limit=0).ls_time_limit == 0.0
end

@testset "time_limit is the budget of the whole call" begin
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    perturbation = TimeRecordingPerturbation(Tuple{Float64,Float64}[])
    t0 = time()
    result = iterated_local_search!(
        sol,
        instance,
        [perturbation];
        config=ILSConfig(;
            time_limit=6,
            perturbation_time_limit=1.5,
            ls_time_limit=1,
            final_ls_time_limit=2,
            max_no_change=1000,
        ),
        rng=Random.MersenneTwister(1),
        verbose=false,
    )
    elapsed = time() - t0
    @test elapsed < 6 + 1.5
    @test result.time_elapsed <= elapsed
    # The last 2 seconds are reserved: no perturbation call runs into them.
    @test !isempty(perturbation.calls)
    @test all(c -> c[1] + c[2] <= t0 + 4 + 0.1, perturbation.calls)
    @test maximum(c -> c[1], perturbation.calls) < t0 + 4
end

@testset "The final local search keeps its reserved time" begin
    # No loop time is left, so only the final local search can improve the greedy cost.
    instance = TestFixtures.small_instance()
    sol = TestFixtures.small_greedy()
    start_cost = cost(sol)
    perturbation = TimeRecordingPerturbation(Tuple{Float64,Float64}[])
    result = iterated_local_search!(
        sol,
        instance,
        [perturbation, GroupReinsertPerturbation()];
        config=ILSConfig(; time_limit=4, final_ls_time_limit=4),
        rng=Random.MersenneTwister(1),
        verbose=false,
    )
    @test isempty(perturbation.calls)
    @test result.iterations == 0
    @test result.best_cost < start_cost
    @test result.time_elapsed < 4 + 1.5
end

@testset "ILSConfig final_ls_time_limit" begin
    @test ILSConfig().final_ls_time_limit == 300.0
    @test ILSConfig(; time_limit=60).final_ls_time_limit == 10.0
    @test ILSConfig(; time_limit=60, final_ls_time_limit=60).final_ls_time_limit == 60.0
    err = try
        ILSConfig(; time_limit=60, final_ls_time_limit=61)
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("61", err.msg) && occursin("60", err.msg)
    @test_throws ArgumentError ILSConfig(; final_ls_time_limit=-1)
    @test_throws ArgumentError ILSConfig(; time_limit=Inf, final_ls_time_limit=Inf)
end

@testset "Perturbations that do not support the instance are skipped" begin
    modes = [(BinPackingArcCost(10.0, 2), 1, 3), (BinPackingArcCost(7.0, 2), 1, 10)]
    multimodal = TestFixtures._leg_instance(modes, 1; quantity=5)
    plain = TestFixtures.small_instance()
    milp = [ArcFlowMILPPerturbation(), AttractReduceMILPPerturbation()]

    @test !supports_instance(ArcFlowMILPPerturbation(), multimodal)
    @test !supports_instance(AttractReduceMILPPerturbation(), multimodal)
    @test supports_instance(GroupReinsertPerturbation(), multimodal)
    @test all(p -> supports_instance(p, plain), milp)

    sol = greedy_heuristic(
        multimodal; mode_selector=FillThenSpillMode(), show_progress=false
    )
    start_cost = cost(sol)
    config = ILSConfig(;
        time_limit=3, final_ls_time_limit=0.5, perturbation_time_limit=1, ls_time_limit=1
    )
    result = @test_logs (:info, r"^Skipping perturbations") match_mode = :any iterated_local_search!(
        sol,
        multimodal,
        [GroupReinsertPerturbation(), milp...];
        config,
        mode_selector=FillThenSpillMode(),
        rng=Random.MersenneTwister(1),
        verbose=true,
    )
    @test result.best_cost <= start_cost + 1e-9
    @test cost(sol) ≈ result.best_cost
    @test is_feasible(Solution(sol, multimodal), multimodal)

    err = try
        iterated_local_search!(sol, multimodal, milp; config, verbose=false)
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("ArcFlowMILPPerturbation", err.msg)
end

# Records the mode selector it receives and changes nothing. The infinite cost increase ends
# each round after one call, and `max_no_change` (3 by default) ends the loop.
struct SelectorRecordingPerturbation <: AbstractPerturbation
    received::Vector{Any}
end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::SelectorRecordingPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    push!(p.received, mode_selector)
    return (Inf, 0)
end

@testset "The ILS passes its mode selector to the perturbations" begin
    instance = TestFixtures.small_instance()
    config = ILSConfig(;
        time_limit=3, final_ls_time_limit=0.5, perturbation_time_limit=1, ls_time_limit=1
    )
    for selector in (FillThenSpillMode(), CheapestMode())
        sol = TestFixtures.small_greedy()
        p = SelectorRecordingPerturbation(Any[])
        iterated_local_search!(
            sol,
            instance,
            [p];
            config,
            mode_selector=selector,
            rng=Random.MersenneTwister(1),
            verbose=false,
        )
        @test length(p.received) == 3
        @test all(==(selector), p.received)
    end
end
