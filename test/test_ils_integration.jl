using Test
using TransportationPlanningOptimization
using Dates
using Random

const TPO = TransportationPlanningOptimization

isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound

# Reuse the mock perturbation pattern from test_ils_loop.jl
struct IntegrationReinsertPerturbation <: AbstractPerturbation end

function TransportationPlanningOptimization.perturbate!(
    sol::Solution,
    instance::Instance,
    p::IntegrationReinsertPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    isempty(instance.bundles) && return (0.0, 0)
    idx = rand(rng, 1:length(instance.bundles))
    isempty(sol.bundle_paths[idx]) && return (0.0, 0)

    before = cost(sol)
    snap = snapshot_solution(sol, instance)
    TPO.remove_bundle_path!(sol, instance, idx)

    ttg = instance.travel_time_graph
    TPO.update_bundle_cost_matrix!(sol, instance, idx)
    origin = ttg.origin_codes[idx]
    destination = ttg.destination_codes[idx]
    parents, _ = TPO.bundle_dijkstra(ttg.graph, origin, ttg.cost_matrix; dst=destination)
    path = TPO.trace_path(parents, origin, destination)
    if !isempty(path)
        TPO.add_bundle_path!(sol, instance, idx, path)
    end
    after = cost(sol)

    # Revert if cost increased by more than 1.5%
    if after > before * 1.015
        restore_solution!(sol, snap, instance)
        return (0.0, 0)
    end
    return (before - after, 1)
end

function build_small_instance()
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    return Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

@testset "Full ILS pipeline: solve_filtered -> LS -> ILS -> feasible" begin
    instance = build_small_instance()

    # Phase 1: initial solution
    sol_data = solve_filtered(instance)
    local_search!(sol_data.solution, sol_data.sub_instance; time_limit=5.0)
    post_ls_cost = cost(sol_data.solution)

    # Phase 2: ILS with slope scaling
    result = iterated_local_search!(
        sol_data.solution,
        sol_data.sub_instance,
        [IntegrationReinsertPerturbation()];
        config=ILSConfig(;
            time_limit=15,
            perturbation_time_limit=3,
            ls_time_limit=5,
            max_no_change=2,
            max_no_improv=2,
        ),
        (cost_update!)=slope_scaling_update!,
        rng=Random.MersenneTwister(42),
        verbose=false,
    )

    @test result isa ILSResult
    @test result.improvement >= 0.0
    @test result.best_cost <= post_ls_cost + 1e-6
    @test is_feasible(sol_data.solution, sol_data.sub_instance)

    # Verify cost_scaling was populated by slope scaling on the sub-instance
    # that ILS actually ran on (solve_filtered builds a fresh sub-instance
    # with its own TravelTimeGraph, distinct from `instance`'s).
    # It may be empty if ILS didn't iterate, but should at least not error.
    @test sol_data.sub_instance.travel_time_graph.cost_scaling isa Dict
end

@testset "Large local search in ILS pipeline" begin
    instance = build_small_instance()
    sol = greedy_heuristic(instance)

    # Run large_local_search! then ILS
    large_local_search!(sol, instance; time_limit=5.0)
    @test is_feasible(sol, instance)

    result = iterated_local_search!(
        sol,
        instance,
        [IntegrationReinsertPerturbation()];
        config=ILSConfig(; time_limit=10, max_no_change=1, max_no_improv=1),
        verbose=false,
    )

    @test result isa ILSResult
    @test is_feasible(sol, instance)
end
