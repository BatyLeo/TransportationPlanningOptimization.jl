using Test
using TransportationPlanningOptimization
using Dates

@testset "lower_bound_incremental_cost equals classic for LinearArcCost" begin
    arc_f = LinearArcCost(2.0)
    C = LightCommodity{true,Nothing}
    new = [
        LightCommodity(;
            origin_id="o",
            destination_id="d",
            size=Float64(s),
            info=nothing,
            is_date_arrival=true,
        ) for s in (3, 5, 7)
    ]
    @test TransportationPlanningOptimization.lower_bound_incremental_cost(
        arc_f, C[], new
    ) == TransportationPlanningOptimization.incremental_cost(arc_f, C[], new)
end

@testset "lower_bound_incremental_cost uses fractional bins" begin
    arc_f = BinPackingArcCost(10.0, 100)
    C = LightCommodity{true,Nothing}
    new = [
        LightCommodity(;
            origin_id="o",
            destination_id="d",
            size=Float64(s),
            info=nothing,
            is_date_arrival=true,
        ) for s in (60, 60)
    ]
    classic = TransportationPlanningOptimization.incremental_cost(arc_f, C[], new)
    lb = TransportationPlanningOptimization.lower_bound_incremental_cost(arc_f, C[], new)

    @test classic == 20.0
    @test isapprox(lb, 12.0; atol=1e-6)
    @test lb <= classic
end

@testset "update_bundle_cost_matrix! with cost_fn produces LB <= classic on BP arcs" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "tiny_nodes.csv"),
        joinpath(datadir, "tiny_legs.csv"),
        joinpath(datadir, "tiny_commodities.csv"),
    )
    instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    empty_sol = Solution(instance)

    TransportationPlanningOptimization.update_bundle_cost_matrix!(empty_sol, instance, 1)
    classic_matrix = copy(instance.travel_time_graph.cost_matrix)

    TransportationPlanningOptimization.update_bundle_cost_matrix!(
        empty_sol,
        instance,
        1;
        cost_fn=TransportationPlanningOptimization.compute_ttg_edge_lower_bound_cost,
    )
    lb_matrix = instance.travel_time_graph.cost_matrix

    # All finite entries of LB matrix should be <= classic
    for i in axes(lb_matrix, 1), j in axes(lb_matrix, 2)
        c, l = classic_matrix[i, j], lb_matrix[i, j]
        if isfinite(c) && isfinite(l)
            @test l <= c + 1e-6
        end
    end
end

@testset "_direct_arc_order_lb_cost: BinPackingArcCost returns ceil bin count" begin
    cost = BinPackingArcCost(10.0, 100)
    f = TransportationPlanningOptimization._direct_arc_order_lb_cost
    @test f(cost, 0.0) == 0.0
    @test f(cost, 25.0) == 10.0
    @test f(cost, 100.0) == 10.0
    @test f(cost, 101.0) == 20.0
    @test f(cost, 250.0) == 30.0
end

@testset "_direct_arc_order_lb_cost: LinearArcCost is fractional" begin
    cost = LinearArcCost(2.0)
    f = TransportationPlanningOptimization._direct_arc_order_lb_cost
    @test f(cost, 0.0) == 0.0
    @test f(cost, 25.0) == 50.0
    @test f(cost, 0.5) == 1.0
end
