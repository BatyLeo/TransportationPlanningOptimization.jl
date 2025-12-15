using NetworkDesignOptimization
using Test
using Aqua
using JET

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
end
