using Test
using Dates
using TransportationPlanningOptimization

include("Inbound.jl")
using .Inbound

@testset "Bin packing checks" begin
    @testset "oversized commodity detection" begin
        arc = NetworkArc(;
            travel_time_steps=1, capacity=typemax(Int), cost=BinPackingArcCost(10.0, 65)
        )
        big = LightCommodity(; origin_id="a", destination_id="b", size=124.02)
        @test_throws DomainError TransportationPlanningOptimization.compute_bin_assignments(
            arc.cost, [big]
        )
    end

    @testset "greedy fails on input with oversized items" begin
        instance_name = "small"
        datadir = joinpath(@__DIR__, "public")
        nodes_file = joinpath(datadir, "$(instance_name)_nodes.csv")
        legs_file = joinpath(datadir, "$(instance_name)_legs.csv")
        commodities_file = joinpath(datadir, "$(instance_name)_commodities.csv")

        (nodes, arcs, commodities) = parse_inbound_instance(
            nodes_file, legs_file, commodities_file
        )
        instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

        @test_throws DomainError greedy_heuristic(instance)
    end

    @testset "is_feasible detects oversized bins" begin
        # rebuild the instance locally for this testset
        instance_name = "small"
        datadir = joinpath(@__DIR__, "public")
        nodes_file = joinpath(datadir, "$(instance_name)_nodes.csv")
        legs_file = joinpath(datadir, "$(instance_name)_legs.csv")
        commodities_file = joinpath(datadir, "$(instance_name)_commodities.csv")
        (nodes, arcs, commodities) = parse_inbound_instance(
            nodes_file, legs_file, commodities_file
        )
        instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

        sol = Solution(instance)
        # set a simple bundle path directly (origin -> destination in TTG)
        sol.bundle_paths[1] = [
            instance.travel_time_graph.origin_codes[1],
            instance.travel_time_graph.destination_codes[1],
        ]
        order = instance.bundles[1].orders[1]
        # project to time-space and populate commodities_on_arcs
        tsg_path = [
            TransportationPlanningOptimization.project_to_time_space_graph(
                node, order, instance
            ) for node in sol.bundle_paths[1]
        ]
        for i in 1:(length(tsg_path) - 1)
            edge = (tsg_path[i], tsg_path[i + 1])
            sol.commodities_on_arcs[edge] = order.commodities
            # insert an oversized bin directly (use the same commodity type as the order)
            C = eltype(order.commodities)
            sol.bin_assignments[edge] = [Bin{C}(C[], 124.02, 65.0, -59.02)]
        end
        @test !is_feasible(sol, instance; verbose=false)
    end
end
