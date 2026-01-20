using Aqua
using JET
using JuliaFormatter
using TransportationPlanningOptimization
using Test

@testset "Code quality (Aqua.jl)" begin
    Aqua.test_all(TransportationPlanningOptimization; deps_compat=(check_extras = false))
end

@testset "Code linting (JET.jl)" begin
    JET.test_package(
        TransportationPlanningOptimization;
        target_modules=[TransportationPlanningOptimization],
    )
end

@testset "JuliaFormatter formatting" begin
    @test JuliaFormatter.format(
        TransportationPlanningOptimization; verbose=false, overwrite=false
    )
end
