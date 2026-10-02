using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound: parse_inbound_instance
using CSV
using DataFrames
using Dates
using Test

function ts_files(dir, name)
    return (joinpath(dir, "$(name)_$(f).csv") for f in ("nodes", "legs", "commodities"))
end

function ts_instance(dir, name; kwargs...)
    (; nodes, arcs, commodities) = parse_inbound_instance(ts_files(dir, name)...; kwargs...)
    return Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

function ts_order_keys(instance)
    return Set(
        (b.origin_id, b.destination_id, o.time_step) for b in instance.bundles for
        o in b.orders
    )
end

@testset "irregular dates follow delivery_time_step" begin
    mktempdir() do dir
        for f in ("nodes", "legs", "commodities")
            cp(
                joinpath(TestFixtures.DATADIR, "small_$(f).csv"),
                joinpath(dir, "small_$(f).csv"),
            )
        end
        path = joinpath(dir, "small_commodities.csv")
        df = DataFrame(CSV.File(path; stringtype=String))
        steps = sort(unique(df.delivery_time_step))
        n = length(steps)
        # step rank r gets date 2025-03-24 + 3 * (n - r) weeks: reversed order, irregular gaps
        rank = Dict(s => r for (r, s) in enumerate(steps))
        df.delivery_date = [
            Dates.format(
                DateTime(2025, 3, 24) + Week(3 * (n - rank[s])), "yyyy-mm-dd HH:MM:SS"
            ) * "+00:00" for s in df.delivery_time_step
        ]
        CSV.write(path, df)

        expected = Set(
            (
                string(r.supplier_account),
                string(r.customer_account),
                r.delivery_time_step - first(steps) + 1,
            ) for r in eachrow(df)
        )
        instance = ts_instance(dir, "small")
        @test instance.time_horizon_length == last(steps) - first(steps) + 1
        @test ts_order_keys(instance) == expected

        calendar = ts_instance(dir, "small"; dates_from_time_step=false)
        @test calendar.time_horizon_length > instance.time_horizon_length
    end
end

@testset "both readings agree on calendar-ordered instances ($name)" for name in
                                                                         ("tiny", "small")
    a = ts_instance(TestFixtures.DATADIR, name)
    b = ts_instance(TestFixtures.DATADIR, name; dates_from_time_step=false)
    @test a.time_horizon_length == b.time_horizon_length
    @test a.time_step_to_date == b.time_step_to_date
    @test ts_order_keys(a) == ts_order_keys(b)
end

@testset "missing delivery_time_step column" begin
    mktempdir() do dir
        for f in ("nodes", "legs", "commodities")
            cp(
                joinpath(TestFixtures.DATADIR, "tiny_$(f).csv"),
                joinpath(dir, "tiny_$(f).csv"),
            )
        end
        path = joinpath(dir, "tiny_commodities.csv")
        CSV.write(path, select(DataFrame(CSV.File(path)), Not(:delivery_time_step)))
        @test_throws ArgumentError parse_inbound_instance(ts_files(dir, "tiny")...)
        @test parse_inbound_instance(
            ts_files(dir, "tiny")...; dates_from_time_step=false
        ) isa NamedTuple
    end
end
