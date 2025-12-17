using Aqua
using JET
using JuliaFormatter
using NetworkDesignOptimization
using Test

@testset "Code quality (Aqua.jl)" begin
    Aqua.test_all(NetworkDesignOptimization; deps_compat=(check_extras = false))
end

@testset "Code linting (JET.jl)" begin
    JET.test_package(NetworkDesignOptimization; target_modules=[NetworkDesignOptimization])
end

@testset "JuliaFormatter formatting" begin
    @test JuliaFormatter.format(NetworkDesignOptimization; verbose=false, overwrite=false)
end
