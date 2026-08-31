# Outbound dataMVP runs across configurations (mono vs multi-modal, time steps)
# for slide 9 of the RenaultPres Juin 2026 deck.
using Dates, Printf, CSV, DataFrames
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

include(joinpath(@__DIR__, "Outbound.jl"))

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "outbound", "dataMVP")
const OUT_DIR = joinpath(@__DIR__, "..", "benchmark", "results")
mkpath(OUT_DIR)

function run_one(label::String, time_step::Period; keep_modes::Bool, allow_multimodal::Bool)
    t_parse = @elapsed (; nodes, arcs, commodities) = Outbound.parse_dataMVP_instance(
        DATA_DIR; keep_modes=keep_modes, all_linear=true
    )
    t_build = @elapsed inst = TPO.Instance(
        nodes,
        arcs,
        commodities,
        time_step;
        wrap_time=false,
        allow_multimodal=allow_multimodal,
    )
    t_greedy = @elapsed sol = TPO.greedy_heuristic(inst)
    return (;
        label,
        time_step=string(time_step),
        keep_modes,
        n_nodes=length(nodes),
        n_arcs=length(arcs),
        n_commodities=length(commodities),
        parse_s=round(t_parse; digits=3),
        build_s=round(t_build; digits=3),
        greedy_s=round(t_greedy; digits=3),
        greedy_cost=TPO.cost(sol),
    )
end

rows = [
    run_one("mono_monthly", Day(30); keep_modes=false, allow_multimodal=false),
    run_one("multi_monthly", Day(30); keep_modes=true, allow_multimodal=true),
    run_one("multi_singlebucket", Day(800); keep_modes=true, allow_multimodal=true),
]

CSV.write(joinpath(OUT_DIR, "outbound_ablation.csv"), DataFrame(rows))
println("Wrote outbound_ablation.csv")
for r in rows
    @printf(
        "[%s]  parse=%.2fs build=%.2fs greedy=%.2fs cost=%.3e\n",
        r.label,
        r.parse_s,
        r.build_s,
        r.greedy_s,
        r.greedy_cost
    )
end
