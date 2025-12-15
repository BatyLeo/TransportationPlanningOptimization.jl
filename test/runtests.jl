using NetworkDesignOptimization
using Test
using Aqua
using JET
using Dates

@testset "NetworkDesignOptimization.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(NetworkDesignOptimization; deps_compat=(check_extras = false))
    end
    @testset "Code linting (JET.jl)" begin
        JET.test_package(NetworkDesignOptimization; target_defined_modules=true)
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
        end
        @testset "Instances" begin
            include("test_instances.jl")
        end
    end
end
