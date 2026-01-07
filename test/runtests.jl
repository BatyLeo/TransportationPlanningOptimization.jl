using Test

@testset "NetworkDesignOptimization.jl" begin
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
            include("test_solution.jl")
            include("test_solution_parsing.jl")
        end
        @testset "Instances" begin
            include("test_instances.jl")
        end
        @testset "Greedy Insertion" begin
            include("test_insertion.jl")
        end
        @testset "Tiny instance" begin
            include("test_tiny_instance.jl")
        end
    end
end
