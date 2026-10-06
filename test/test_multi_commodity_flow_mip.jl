using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.MultiCommodityFlow
using JuMP: OPTIMAL, INFEASIBLE
using Test

# Same tiny 3-node instance as test_multi_commodity_flow_parser.jl.
dow = """
MULTIGEN.DAT:
   3   3   2
   1   3   1   5   1   1   1
   1   2   3   100   10   1   2
   2   3   3   100   10   1   3
   1   3   10
   2   3   5
"""

@testset "Tiny instance MIP (UMCF)" begin
    data = MultiCommodityFlow._parse_canad_data(IOBuffer(dow))
    res = MultiCommodityFlow._benchmark_solve(data)

    @test res.termination_status == OPTIMAL
    @test res.objective_value ≈ 75
    @test !isnothing(res.solution)
    @test is_feasible(res.solution, res.instance; verbose=true)
    mip = MultiCommodityFlow._solve_mip(data)
    @test cost(res.solution) ≈ mip.objective

    # Each route follows the arcs chosen by the MIP from origin to destination.
    arc_paths = mip.arc_paths
    for k in eachindex(data.origins)
        arcs = [leg.arc for leg in res.solution.routes[k]]
        @test arcs == arc_paths[k]
        @test data.tails[first(arcs)] == data.origins[k]
        @test data.heads[last(arcs)] == data.destinations[k]
        @test all(data.heads[a] == data.tails[b] for (a, b) in zip(arcs, arcs[2:end]))
    end

    greedy = greedy_heuristic(res.instance; show_progress=false)
    @test res.objective_value <= cost(greedy)
end

@testset "Tiny instance MIP (no incumbent)" begin
    # Single arc, capacity 1 < demand 10: the only path is infeasible.
    data = MultiCommodityFlow._MCFData(;
        n_nodes=2,
        tails=[1],
        heads=[2],
        var_costs=[1],
        capacities=[1],
        fixed_costs=[0],
        origins=[1],
        destinations=[2],
        demands=[10],
    )
    res = MultiCommodityFlow._benchmark_solve(data)

    @test res.termination_status == INFEASIBLE
    @test isnothing(res.solution)
    @test res.objective_value == Inf
    @test res.objective_bound == Inf
end

@testset "Same endpoints, different paths" begin
    # Two unit commodities 1 -> 2, the direct arc 1 -> 2 only holds one of them,
    # the other takes the detour 1 -> 3 -> 2.
    data = MultiCommodityFlow._MCFData(;
        n_nodes=3,
        tails=[1, 1, 3],
        heads=[2, 3, 2],
        var_costs=[1, 1, 1],
        capacities=[1, 1, 1],
        fixed_costs=[0, 0, 0],
        origins=[1, 1],
        destinations=[2, 2],
        demands=[1, 1],
    )
    res = MultiCommodityFlow._benchmark_solve(data)

    @test bundle_count(res.instance) == 2
    @test res.termination_status == OPTIMAL
    @test res.objective_value ≈ 3
    @test is_feasible(res.solution, res.instance; verbose=true)
    @test cost(res.solution) ≈ MultiCommodityFlow._solve_mip(data).objective
    @test length(unique([leg.arc for leg in route] for route in res.solution.routes)) == 2
end

@testset "Tiny instance MIP (network design)" begin
    data = MultiCommodityFlow._parse_canad_data(IOBuffer(dow); network_design=true)
    res = MultiCommodityFlow._benchmark_solve(data)

    @test res.termination_status == OPTIMAL
    @test res.objective_value ≈ 95
    @test !isnothing(res.solution)
    @test is_feasible(res.solution, res.instance; verbose=true)
    @test cost(res.solution) ≈ MultiCommodityFlow._solve_mip(data).objective

    greedy = greedy_heuristic(res.instance; show_progress=false)
    @test res.objective_value <= cost(greedy)
end

@testset "Canad C c33 MIP" begin
    withenv("DATADEPS_ALWAYS_ACCEPT" => "true") do
        @testset "UMCF" begin
            res = benchmark_solve(CanadC(), "c33"; time_limit=300.0)
            @test res.termination_status == OPTIMAL
            @test is_feasible(res.solution, res.instance; verbose=true)
            if res.termination_status == OPTIMAL
                @test isapprox(res.objective_value, 361_499; rtol=1e-4)
            end

            greedy_cost = cost(greedy_heuristic(res.instance; show_progress=false))
            lb = cost(lower_bound(res.instance; show_progress=false))
            @test lb <= res.objective_value <= greedy_cost + 1e-6
        end

        @testset "Network design" begin
            res = benchmark_solve(CanadC(), "c33"; network_design=true, time_limit=60.0)
            @test !isnothing(res.solution)
            @test is_feasible(res.solution, res.instance; verbose=true)

            greedy_cost = cost(greedy_heuristic(res.instance; show_progress=false))
            @test res.objective_value <= greedy_cost + 1e-6
            if res.termination_status == OPTIMAL
                @test isapprox(res.objective_value, 423_933; rtol=1e-4)
            end
        end
    end
end
