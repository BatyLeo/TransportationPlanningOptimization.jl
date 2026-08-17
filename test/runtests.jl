using Test

include("Inbound.jl")
using .Inbound

@testset "TransportationPlanningOptimization.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        include("code.jl")
    end
    @testset "Time step helpers" begin
        include("test_time_step_helpers.jl")
    end
    @testset "Data Structures" begin
        @testset "Commodities" begin
            include("test_commodities.jl")
        end
        @testset "Orders" begin
            include("test_orders.jl")
        end
        @testset "Bundles" begin
            include("test_bundles.jl")
        end
        @testset "Graphs" begin
            include("test_graphs.jl")
            include("test_travel_time_cost_matrix.jl")
            include("test_multi_modal.jl")
            include("test_solution.jl")
            include("test_solution_parsing.jl")
            include("test_lower_bound_cost.jl")
        end
        @testset "IndexCache" begin
            include("test_index_cache.jl")
        end
        @testset "Solution removal" begin
            include("test_solution_removal.jl")
        end
        @testset "Instances" begin
            include("test_instances.jl")
        end
        @testset "Greedy Insertion" begin
            include("test_insertion.jl")
        end
        @testset "Lower bound" begin
            include("test_lower_bound.jl")
        end
        @testset "Instance extraction" begin
            include("test_instance_extraction.jl")
        end
        @testset "Local search" begin
            include("test_local_search.jl")
        end
        @testset "Two-node consolidation" begin
            include("test_two_node_consolidation.jl")
        end
        @testset "Tiny instance" begin
            include("test_tiny_instance.jl")
        end
        include("test_mix_start.jl")
        include("test_solve_filtered.jl")
        @testset "Forbidden constraints" begin
            include("test_forbidden_constraints.jl")
        end
        @testset "Bin packing checks" begin
            include("test_bin_packing.jl")
            include("test_tentative_bin_packing.jl")
        end
        @testset "Frozen packing default" begin
            include("test_frozen_packing.jl")
        end
        @testset "SumArcCost" begin
            include("test_sum_arc_cost.jl")
        end
        @testset "NodeCost" begin
            include("test_node_cost.jl")
        end
        @testset "Inbound extensions" begin
            include("test_inbound_extensions.jl")
        end
        @testset "Drain first matches" begin
            include("test_drain_first_matches.jl")
        end
        @testset "Merge sorted slot" begin
            include("test_merge_sorted_slot.jl")
        end
    end
    @testset "Quick Start" begin
        include("test_quickstart.jl")
    end
end
