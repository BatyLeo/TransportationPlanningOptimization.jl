using Test
using TransportationPlanningOptimization
using Dates

const TPO = TransportationPlanningOptimization

isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound

@testset "snapshot_solution creates independent copy" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    original_cost = cost(sol)

    snap = snapshot_solution(sol, instance)
    @test cost(snap) ≈ original_cost

    # Mutate the original solution
    local_search!(sol, instance; time_limit=5.0)

    # Snapshot must be unaffected
    @test cost(snap) ≈ original_cost
    @test cost(sol) != cost(snap) || cost(sol) ≈ original_cost  # LS may or may not improve
end

@testset "restore_solution! restores to snapshot state" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    original_cost = cost(sol)
    original_paths = deepcopy(sol.bundle_paths)

    snap = snapshot_solution(sol, instance)

    # Mutate via local search
    local_search!(sol, instance; time_limit=5.0)
    @test cost(sol) <= original_cost + 1e-6  # should not degrade

    # Restore
    restore_solution!(sol, snap, instance)
    @test cost(sol) ≈ original_cost atol = 1e-6
    @test sol.bundle_paths == original_paths
    @test is_feasible(sol, instance)
end

@testset "restore then re-run local search" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    snap = snapshot_solution(sol, instance)

    local_search!(sol, instance; time_limit=5.0)
    restore_solution!(sol, snap, instance)

    # Solution must still be usable after restore
    local_search!(sol, instance; time_limit=5.0)
    @test is_feasible(sol, instance)
end
