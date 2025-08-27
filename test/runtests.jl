using NetworkDesignOptimization
using Test
using Aqua
using JET

@testset "NetworkDesignOptimization.jl" begin
    @testset "Code quality (Aqua.jl)" begin
        Aqua.test_all(NetworkDesignOptimization)
    end
    @testset "Code linting (JET.jl)" begin
        JET.test_package(NetworkDesignOptimization; target_defined_modules = true)
    end
    # Write your tests here.
end
