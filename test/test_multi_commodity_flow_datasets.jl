using TransportationPlanningOptimization.Problems.MultiCommodityFlow
using Test

withenv("DATADEPS_ALWAYS_ACCEPT" => "true") do
    @testset "CanadC" begin
        names = list_instances(CanadC())
        @test length(names) == 31
        @test first(names) == "c33"
        @test isfile(joinpath(MultiCommodityFlow.dataset_dir(CanadC()), "c33.dow"))
    end

    @testset "datasets" begin
        @test MultiCommodityFlow.datasets() == [CanadC()]
    end
end
