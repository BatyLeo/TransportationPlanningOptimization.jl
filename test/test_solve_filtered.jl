using Test
using Dates
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

isdefined(Main, :TestFixtures) || include("fixtures.jl")
using .TestFixtures

@testset "solve_filtered returns feasible solution on the sub-instance" begin
    instance = TestFixtures.small_instance()

    result = TPO.solve_filtered(instance; show_progress=false)

    @test result isa NamedTuple
    @test haskey(result, :solution)
    @test haskey(result, :sub_instance)
    @test TPO.is_feasible(result.solution, result.sub_instance)
    @test isfinite(TPO.cost(result.solution))
end

@testset "solve_filtered -> local_search! -> merge_solutions is feasible when a filtered bundle shares an arc with a kept bundle" begin
    # F (A->B, size 3) is a trivial direct path, so filtering drops it and
    # `preload_filtered_bundles` reserves its load on A->B. K (A->D2, size 4)
    # has a cheap route through B and a costlier fallback through C, so its
    # real solve must see A->B as partly spoken for and route around it.
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:other),      # F's destination, also K's cheap hop
        NetworkNode(; id="C", node_type=:other),      # K's alternate, costlier hop
        NetworkNode(; id="D2", node_type=:destination), # K's destination
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=5,
        ),
        Arc(;
            origin_id="B", destination_id="D2", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="C", cost=LinearArcCost(2.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="C", destination_id="D2", cost=LinearArcCost(2.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        # F: direct A->B, size 3. Filtering keeps this as a trivial (length-2)
        # path -> filtered out.
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=3.0,
        ),
        # K: A->D2, must go through B or C, size 4. Non-trivial path -> kept.
        Commodity(;
            origin_id="A",
            destination_id="D2",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=4.0,
        ),
    ]
    instance = Instance(nodes, arcs, commodities, Day(1))

    result = TPO.solve_filtered(instance; show_progress=false)
    TPO.local_search!(result.solution, result.sub_instance; time_limit=1.0)
    @test TPO.is_feasible(result.solution, result.sub_instance; verbose=true)
    merged = TPO.merge_solutions(
        TPO.lower_bound_filtering(instance; show_progress=false),
        result.solution,
        instance,
        result.sub_instance,
    )
    @test TPO.is_feasible(merged, instance; verbose=true)
end
