using Test
using Dates
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

# Already in Main from runtests.jl, but be defensive in case the file is loaded
# standalone via include from the REPL.
isdefined(Main, :Inbound) || include("Inbound.jl")
using .Inbound: parse_inbound_instance

# Frozen bin packing is the default. FFD-union remains a valid opt-in. Both
# must produce feasible solutions and finite costs that agree to within a few
# percent (they differ only by FFD tie-breaks and the union re-pack).
@testset "Frozen packing default and ffd_union opt-in agree" begin
    datadir = joinpath(@__DIR__, "public")
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(datadir, "small_nodes.csv"),
        joinpath(datadir, "small_legs.csv"),
        joinpath(datadir, "small_commodities.csv"),
    )
    instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    # Default packing is :frozen.
    frozen_sol = TPO.greedy_heuristic(instance)
    @test TPO.is_feasible(frozen_sol, instance)
    frozen_cost = TPO.cost(frozen_sol)
    @test isfinite(frozen_cost)

    # FFD-union remains a valid opt-in.
    ffd_sol = TPO.greedy_heuristic(instance; packing=:ffd_union)
    @test TPO.is_feasible(ffd_sol, instance)
    ffd_cost = TPO.cost(ffd_sol)
    @test isfinite(ffd_cost)

    # The two packings agree to within a few percent.
    @test isapprox(frozen_cost, ffd_cost; rtol=5e-2)

    # The mixed solution under the frozen default is feasible.
    mixed = TPO.mix_greedy_and_lower_bound(instance).mixed
    @test TPO.is_feasible(mixed, instance)
    @test isfinite(TPO.cost(mixed))
end
