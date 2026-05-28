# TPO-only performance harness for the runtime optimization campaign.
#
# Run with: julia --project=scripts
#   include("scripts/benchmark/profile_tpo.jl")
#   capture_golden()              # once, before optimizing
#   record_result("baseline", "large")
#   profile_stage("large", :mix)  # rank hotspots
#   ... apply an optimization ...
#   check_correctness()           # must print PASS
#   record_result("targeted reset", "large")
#
# Not a test: long-running, exploratory, prints profiles.

using Dates
using Printf
using Profile
using DataFrames
using CSV

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")
const OUTPUT_DIR = joinpath(@__DIR__, "results")
const PROFILE_INSTANCES = ["small", "medium", "large"]

function load_instance(name::String)
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(DATA_DIR, "$(name)_nodes.csv"),
        joinpath(DATA_DIR, "$(name)_legs.csv"),
        joinpath(DATA_DIR, "$(name)_commodities.csv"),
    )
    return TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

"The four costs every optimization must preserve."
function compute_costs(instance; packing::Symbol=:frozen)
    return (;
        greedy=TPO.cost(TPO.greedy_heuristic(instance; packing=packing)),
        lower_bound=TPO.cost(TPO.lower_bound(instance)),
        filtering=TPO.cost(TPO.lower_bound_filtering(instance)),
        mix=TPO.cost(TPO.mix_greedy_and_lower_bound(instance; packing=packing).mixed),
    )
end

"Capture golden costs once, before any optimization. Persists to CSV."
function capture_golden()
    isdir(OUTPUT_DIR) || mkpath(OUTPUT_DIR)
    rows = DataFrame()
    for name in PROFILE_INSTANCES
        c = compute_costs(load_instance(name))
        rows = vcat(
            rows,
            DataFrame(;
                instance=name,
                greedy=c.greedy,
                lower_bound=c.lower_bound,
                filtering=c.filtering,
                mix=c.mix,
            ),
        )
    end
    CSV.write(joinpath(OUTPUT_DIR, "golden_costs.csv"), rows)
    println("Golden costs captured for ", join(PROFILE_INSTANCES, ", "))
    return rows
end

"Recompute costs and assert they match the golden values. Returns true if all match."
function check_correctness(; rtol=1e-9)
    golden = DataFrame(CSV.File(joinpath(OUTPUT_DIR, "golden_costs.csv")))
    all_ok = true
    for row in eachrow(golden)
        c = compute_costs(load_instance(String(row.instance)))
        for stage in (:greedy, :lower_bound, :filtering, :mix)
            got = getproperty(c, stage)
            want = row[stage]
            ok = isapprox(got, want; rtol=rtol)
            ok || (all_ok = false)
            @printf(
                "  %-8s %-12s want=%.6e got=%.6e  %s\n",
                row.instance,
                stage,
                want,
                got,
                ok ? "OK" : "MISMATCH",
            )
        end
    end
    println(all_ok ? "CORRECTNESS: PASS" : "CORRECTNESS: FAIL")
    return all_ok
end

"Best-of-`reps` wall-clock seconds per stage on `name` (warmup excluded)."
function time_stages(name::String; reps::Int=3, packing::Symbol=:frozen)
    inst = load_instance(name)
    # Warmup to exclude JIT.
    TPO.greedy_heuristic(inst; packing=packing)
    TPO.lower_bound(inst)
    TPO.lower_bound_filtering(inst)
    TPO.mix_greedy_and_lower_bound(inst; packing=packing)
    best(f) = minimum((@elapsed f()) for _ in 1:reps)
    return (;
        greedy=best(() -> TPO.greedy_heuristic(inst; packing=packing)),
        lower_bound=best(() -> TPO.lower_bound(inst)),
        filtering=best(() -> TPO.lower_bound_filtering(inst)),
        mix=best(() -> TPO.mix_greedy_and_lower_bound(inst; packing=packing)),
    )
end

"Time `name` and append a labelled row to perf_campaign.md."
function record_result(label::String, name::String; reps::Int=3)
    isdir(OUTPUT_DIR) || mkpath(OUTPUT_DIR)
    t = time_stages(name; reps=reps)
    path = joinpath(OUTPUT_DIR, "perf_campaign.md")
    new = !isfile(path)
    open(path, "a") do io
        if new
            println(io, "# Runtime performance campaign (instance: ", name, ")")
            println(io)
            println(io, "Best-of-$reps wall-clock seconds per stage.")
            println(io)
            println(io, "| label | greedy_s | lower_bound_s | filtering_s | mix_s |")
            println(io, "| --- | --- | --- | --- | --- |")
        end
        @printf(
            io,
            "| %s | %.3f | %.3f | %.3f | %.3f |\n",
            label,
            t.greedy,
            t.lower_bound,
            t.filtering,
            t.mix,
        )
    end
    @printf(
        "%-20s greedy=%.3f lb=%.3f filter=%.3f mix=%.3f\n",
        label,
        t.greedy,
        t.lower_bound,
        t.filtering,
        t.mix,
    )
    return t
end

"Profile one stage on `name` and print a flat, count-sorted hotspot list."
function profile_stage(name::String, stage::Symbol)
    inst = load_instance(name)
    f = if stage === :greedy
        () -> TPO.greedy_heuristic(inst)
    elseif stage === :lower_bound
        () -> TPO.lower_bound(inst)
    elseif stage === :filtering
        () -> TPO.lower_bound_filtering(inst)
    elseif stage === :mix
        () -> TPO.mix_greedy_and_lower_bound(inst)
    else
        error("unknown stage $stage")
    end
    f()  # warmup
    Profile.clear()
    Profile.@profile f()
    Profile.print(; format=:flat, sortedby=:count, mincount=10)
    return nothing
end
