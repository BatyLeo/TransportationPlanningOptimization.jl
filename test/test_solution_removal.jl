using Test
using TransportationPlanningOptimization
using Dates

const TPO = TransportationPlanningOptimization

@testset "TPO.remove_bundle_path! on tiny instance" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)

    @test cost(sol) > 0
    @test !isempty(sol.bundle_paths[1])
    saved_path = copy(sol.bundle_paths[1])

    TPO.remove_bundle_path!(sol, instance, 1)
    @test isempty(sol.bundle_paths[1])

    TPO.add_bundle_path!(sol, instance, 1, saved_path)
    @test sol.bundle_paths[1] == saved_path
end

@testset "TPO.remove_bundle_path! preserves cost after add-remove-add cycle" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    # The round-trip cost-preservation invariant holds only under
    # order-independent packing: `TPO.remove_bundle_path!` always re-packs the
    # affected arcs with FFD-union, so re-adding the same commodities must use
    # the same FFD-union semantics to recover the original cost. The production
    # default (`:frozen`) is order-dependent (it grows cached bins in insertion
    # order), so re-adding bundles in a different order than the greedy built
    # them would legitimately change the bin counts. This test pins the
    # invariant for the FFD-union mode that the remove machinery relies on.
    sol = greedy_heuristic(instance; packing=:ffd_union)
    c_before = cost(sol)
    saved_paths = [copy(p) for p in sol.bundle_paths]

    for i in eachindex(saved_paths)
        TPO.remove_bundle_path!(sol, instance, i)
    end
    @test all(isempty, sol.bundle_paths)
    @test isapprox(cost(sol), 0.0; atol=1e-6)

    for i in eachindex(saved_paths)
        TPO.add_bundle_path!(sol, instance, i, saved_paths[i]; packing=:ffd_union)
    end
    @test isapprox(cost(sol), c_before; atol=1e-6)
end

@testset "TPO.remove_bundle_path! on MultiModalArc add-remove-add cycle" begin
    # Two parallel modes with the same transit time collapse to a single
    # MultiModalArc edge in the TSG, exercising the MultiAssignment dispatch
    # of _remove_commodities_from_assignment!.
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(5.0),
            travel_time=Day(1),
            capacity=1,
        ),
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(10.0),
            travel_time=Day(1),
            capacity=10,
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=2,
            departure_date=DateTime(2024, 1, 1),
            max_delivery_time=Day(1),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true)
    sol = greedy_heuristic(instance; mode_selector=FillThenSpillMode())
    @test is_feasible(sol, instance)

    c_before = cost(sol)
    saved_path = copy(sol.bundle_paths[1])
    @test !isempty(saved_path)

    TPO.remove_bundle_path!(sol, instance, 1)
    @test isempty(sol.bundle_paths[1])
    @test isapprox(cost(sol), 0.0; atol=1e-6)

    TPO.add_bundle_path!(sol, instance, 1, saved_path; mode_selector=FillThenSpillMode())
    @test sol.bundle_paths[1] == saved_path
    @test isapprox(cost(sol), c_before; atol=1e-6)
end

@testset "double TPO.remove_bundle_path! is a no-op" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    c_before = cost(sol)

    TPO.remove_bundle_path!(sol, instance, 1)
    cost_once = cost(sol)
    TPO.remove_bundle_path!(sol, instance, 1)
    cost_twice = cost(sol)

    @test isapprox(cost_once, cost_twice; atol=1e-6)
    @test isempty(sol.bundle_paths[1])
end

@testset "partial removal makes solution infeasible" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    @test is_feasible(sol, instance)

    TPO.remove_bundle_path!(sol, instance, 1)
    @test !is_feasible(sol, instance; verbose=false)
end

@testset "TPO.add_bundle_path! and TPO.remove_bundle_path! return cost deltas" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = greedy_heuristic(instance)
    c0 = cost(sol)
    saved_path = copy(sol.bundle_paths[1])

    removed_delta = TPO.remove_bundle_path!(sol, instance, 1)
    c1 = cost(sol)
    @test isapprox(removed_delta, c1 - c0; atol=1e-6)
    @test removed_delta <= 1e-9  # non-positive (allow tiny FP slack)

    added_delta = TPO.add_bundle_path!(sol, instance, 1, saved_path)
    c2 = cost(sol)
    @test isapprox(added_delta, c2 - c1; atol=1e-6)
    @test added_delta >= -1e-9

    @test isapprox(c2, c0; atol=1e-6)
end
