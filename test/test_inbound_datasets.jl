using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound
using Dates: Week
using Test

withenv("DATADEPS_ALWAYS_ACCEPT" => "true") do
    @testset "RenaultInbound" begin
        names = list_instances(RenaultInbound())
        @test length(names) == 9
        @test first(names) == "extra_large"
        @test last(names) == "world5"

        instance = load_instance(RenaultInbound(), "small")
        datadir = joinpath(@__DIR__, "public")
        (; nodes, arcs, commodities) = parse_inbound_instance(
            (
                joinpath(datadir, "small_$(f).csv") for
                f in ("nodes", "legs", "commodities")
            )...,
        )
        # the `cross_plat` platform loops are dropped by the parser
        @test all(a -> a.origin_id != a.destination_id, arcs)
        expected = Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
        @test bundle_count(instance) == bundle_count(expected)
        @test commodity_count(instance) == commodity_count(expected)
        @test length(instance.time_step_to_date) == length(expected.time_step_to_date)
    end

    @testset "datasets" begin
        @test Inbound.datasets() == [RenaultInbound()]
    end
end
