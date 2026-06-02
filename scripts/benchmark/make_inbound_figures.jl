using CSV, DataFrames, Plots
gr()

const RESULTS_CSV = joinpath(@__DIR__, "results", "comparison.csv")
const FIG_DIR = joinpath(@__DIR__, "..", "..", "..", "RenaultPres", "jun26", "figures")
mkpath(FIG_DIR)

df = CSV.read(RESULTS_CSV, DataFrame)
labels = df.instance
n = length(labels)

# --- Figure 1: per-step times TPO vs STP.
# Only the run-to-completion steps (build, filter, greedy/init) are timed in a
# comparable way. Local search runs to a fixed equal wall-clock budget in both
# packages, so its duration is not a speed measurement and is excluded here.
# Two adjacent stacked bars per instance (TPO then STP), segmented by step.
steps = ["build", "filter", "greedy"]
tpo_steps = [df.tpo_build_s df.tpo_filter_s df.tpo_init_s]   # n x 3
stp_steps = [df.stp_build_s df.stp_filter_s df.stp_init_s]   # n x 3
step_colors = [:steelblue :seagreen :goldenrod]

x = collect(1:n)
p1 = plot(;
    xlabel="Instance",
    ylabel="Temps (s)",
    title="Temps par étape — TPO (gauche) vs STP (droite)",
    legend=:topleft,
)
# stacked TPO bars (left of each instance), then STP bars (right)
for (j, step) in enumerate(steps)
    tpo_bottom = j == 1 ? zeros(n) : vec(sum(tpo_steps[:, 1:(j - 1)]; dims=2))
    stp_bottom = j == 1 ? zeros(n) : vec(sum(stp_steps[:, 1:(j - 1)]; dims=2))
    bar!(
        p1,
        x .- 0.2,
        tpo_steps[:, j];
        bar_width=0.36,
        fillrange=tpo_bottom,
        color=step_colors[j],
        label=step,
    )
    bar!(
        p1,
        x .+ 0.2,
        stp_steps[:, j];
        bar_width=0.36,
        fillrange=stp_bottom,
        color=step_colors[j],
        label="",
    )
end
xticks!(p1, x, labels)
savefig(p1, joinpath(FIG_DIR, "inbound_step_times.pdf"))

# --- Figure 2: cost ratios per instance (quality TPO / STP).
p2 = bar(
    labels,
    df.init_cost_ratio;
    label="Greedy (TPO/STP)",
    color=:steelblue,
    ylabel="Ratio de coût",
    xlabel="Instance",
    title="Qualité TPO/STP (≤ 1 = TPO meilleur)",
    ylim=(0.95, 1.05),
)
bar!(
    p2,
    labels,
    df.ls_cost_ratio;
    label="Après local search (TPO/STP)",
    color=:goldenrod,
    alpha=0.6,
)
hline!(p2, [1.0]; color=:black, linestyle=:dash, label=false)
savefig(p2, joinpath(FIG_DIR, "inbound_cost_ratios.pdf"))

# --- Console summary for slide-6 text.
build_ratio = df.tpo_build_s ./ df.stp_build_s
println("Wrote inbound_step_times.pdf and inbound_cost_ratios.pdf to $FIG_DIR")
println("Summary:")
println(
    "  Geomean init-cost ratio (TPO/STP): ",
    round(exp(sum(log.(df.init_cost_ratio)) / n); digits=4),
)
println(
    "  Geomean LS-cost ratio (TPO/STP):   ",
    round(exp(sum(log.(df.ls_cost_ratio)) / n); digits=4),
)
println(
    "  Build-time ratio TPO/STP (min..max): ",
    round(minimum(build_ratio); digits=2),
    " .. ",
    round(maximum(build_ratio); digits=2),
)
