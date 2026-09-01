using Test

include("Inbound.jl")
using .Inbound

include("fixtures.jl")
using .TestFixtures

@testset "TransportationPlanningOptimization.jl" begin
    @testset "Code quality" begin
        @testset "Aqua.jl" begin
            include("code.jl")
        end
    end

    @testset "Data structures" begin
        @testset "Commodities" begin
            include("test_commodities.jl")
        end
        @testset "Orders" begin
            include("test_orders.jl")
        end
        @testset "Bundles" begin
            include("test_bundles.jl")
        end
    end

    @testset "Packing" begin
        @testset "Bin packing checks" begin
            include("test_bin_packing.jl")
            include("test_tentative_bin_packing.jl")
        end
        @testset "Frozen packing default" begin
            include("test_frozen_packing.jl")
        end
        @testset "Merge sorted slot" begin
            include("test_merge_sorted_slot.jl")
        end
        @testset "Drain first matches" begin
            include("test_drain_first_matches.jl")
        end
    end

    @testset "Graphs and instances" begin
        @testset "Time step helpers" begin
            include("test_time_step_helpers.jl")
        end
        @testset "Graphs" begin
            include("test_graphs.jl")
        end
        @testset "Travel time cost matrix" begin
            include("test_travel_time_cost_matrix.jl")
        end
        @testset "Multi-modal" begin
            include("test_multi_modal.jl")
        end
        @testset "IndexCache" begin
            include("test_index_cache.jl")
        end
        @testset "Instances" begin
            include("test_instances.jl")
        end
        @testset "Tiny instance" begin
            include("test_tiny_instance.jl")
        end
        @testset "Forbidden constraints" begin
            include("test_forbidden_constraints.jl")
        end
    end

    @testset "Cost models" begin
        @testset "Cost scaling" begin
            include("test_cost_scaling.jl")
        end
        @testset "SumArcCost" begin
            include("test_sum_arc_cost.jl")
        end
        @testset "NodeCost" begin
            include("test_node_cost.jl")
        end
        @testset "Slope scaling" begin
            include("test_slope_scaling.jl")
        end
        @testset "Inbound extensions" begin
            include("test_inbound_extensions.jl")
        end
    end

    @testset "Solutions" begin
        @testset "Solution" begin
            include("test_solution.jl")
        end
        @testset "Solution parsing" begin
            include("test_solution_parsing.jl")
        end
        @testset "Solution removal" begin
            include("test_solution_removal.jl")
        end
        @testset "Lower bound" begin
            include("test_lower_bound.jl")
        end
        @testset "Lower bound cost" begin
            include("test_lower_bound_cost.jl")
        end
        @testset "Snapshot" begin
            include("test_snapshot.jl")
        end
    end

    @testset "Algorithms" begin
        @testset "Greedy Insertion" begin
            include("test_insertion.jl")
        end
        @testset "Local search" begin
            include("test_local_search.jl")
        end
        @testset "Large local search" begin
            include("test_large_local_search.jl")
        end
        @testset "Two-node consolidation" begin
            include("test_two_node_consolidation.jl")
        end
        @testset "Instance extraction" begin
            include("test_instance_extraction.jl")
        end
        @testset "Mix start" begin
            include("test_mix_start.jl")
        end
        @testset "Solve filtered" begin
            include("test_solve_filtered.jl")
        end
    end

    @testset "ILS and integration" begin
        @testset "ILS types" begin
            include("test_ils_types.jl")
        end
        @testset "ILS loop" begin
            include("test_ils_loop.jl")
        end
        @testset "ILS integration" begin
            include("test_ils_integration.jl")
        end
    end

    @testset "Quick start" begin
        include("test_greedy.jl")
    end
end
