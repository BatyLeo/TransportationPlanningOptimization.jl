# TPO vs STP: full-pipeline performance and quality comparison.
#
# Runs each package's heuristic pipeline on the inbound benchmark instances and
# writes a side-by-side comparison of per-step costs, wall-clock times,
# local-search throughput, and cross-package feasibility.
#
# Run with:
#   julia --project=scripts scripts/inbound/compare_inbound_to_stp.jl
#
# Results are written incrementally to:
#   scripts/benchmark/results/comparison.csv
#   scripts/benchmark/results/comparison.md

using Dates
using Printf
using DataFrames
using CSV

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using ShipperTransportationPlanning
const STP = ShipperTransportationPlanning
using MetaGraphsNext: MetaGraphsNext

include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "inbound")
const OUTPUT_DIR = joinpath(@__DIR__, "..", "benchmark", "results")

# Instances to compare, smallest first. Comment out large ones for a quick run.
const INSTANCES = [
    "small",
    "medium",
    "large",
    "extra_large",
    "world",
    "world2",
    "world3",
    "world4",
    "world5",
]

# Local-search wall-clock budget (seconds). Both packages get the same budget
# on the same instance.
const LS_TIME_LIMITS = Dict(
    "small" => 10,
    "medium" => 30,
    "large" => 60,
    "extra_large" => 120,
    "world" => 180,
    "world2" => 240,
    "world3" => 300,
    "world4" => 360,
    "world5" => 600,
)
_ls_limit(name::String) = get(LS_TIME_LIMITS, name, 60)

const INCLUDE_ILS = false
const ILS_TIME_LIMITS = Dict(name => 2 * lim for (name, lim) in LS_TIME_LIMITS)
_ils_limit(name::String) = get(ILS_TIME_LIMITS, name, 120)

# Skip instances that already have a row in the CSV (resumable across runs).
const SKIP_EXISTING = true

# ---------------------------------------------------------------------------
# Cross-package translation helpers (for feasibility round-trip)
# ---------------------------------------------------------------------------

function _stp_account_to_node(stp_instance)
    g = stp_instance.networkGraph.graph
    out = Dict{String,STP.NetworkNode}()
    for label in MetaGraphsNext.labels(g)
        node = g[label]
        out[node.account] = node
    end
    return out
end

function _tpo_to_stp_code(tpo_code::Int, tpo_instance, stp_instance, stp_node_by_account)
    label = MetaGraphsNext.label_for(tpo_instance.travel_time_graph.graph, tpo_code)
    sid, tau = label
    haskey(stp_node_by_account, sid) || return nothing
    node = stp_node_by_account[sid]
    return get(stp_instance.travelTimeGraph.hashToIdx, hash(tau, node.hash), nothing)
end

function _translate_tpo_to_stp(tpo_sol, tpo_instance, stp_instance)
    stp_node_by_account = _stp_account_to_node(stp_instance)
    out = Dict{Tuple{String,String},Vector{Int}}()
    for (i, bundle) in enumerate(tpo_instance.bundles)
        path = tpo_sol.bundle_paths[i]
        isempty(path) && continue
        translated = Int[]
        ok = true
        for code in path
            mapped = _tpo_to_stp_code(
                code, tpo_instance, stp_instance, stp_node_by_account
            )
            if mapped === nothing
                ok = false
                break
            end
            push!(translated, mapped)
        end
        ok || continue
        out[(bundle.origin_id, bundle.destination_id)] = translated
    end
    return out
end

function _build_stp_from_translated(
    paths_by_od::Dict{Tuple{String,String},Vector{Int}}, stp_instance
)
    sol = STP.Solution(stp_instance)
    for (_, bundle) in enumerate(stp_instance.bundles)
        key = (bundle.supplier.account, bundle.customer.account)
        haskey(paths_by_od, key) || continue
        STP.update_solution!(
            sol, stp_instance, bundle, copy(paths_by_od[key]); sorted=true
        )
    end
    return sol
end

# ---------------------------------------------------------------------------
# STP helpers
# ---------------------------------------------------------------------------

"Pick the min-cost feasible STP solution among mixed, greedy, lower bound."
function _stp_choose_best(mix_sol, greedy_sol, lb_sol, sub)
    candidates = [mix_sol, greedy_sol, lb_sol]
    feasible = filter(s -> STP.is_feasible(sub, s), candidates)
    pool = isempty(feasible) ? candidates : feasible
    costs = [STP.compute_cost(sub, s) for s in pool]
    return STP.solution_deepcopy(pool[argmin(costs)], sub)
end

"Extract `i` from STP's `Loop Break : time = X, i = Y, noImprov = Z` log."
function _parse_stp_loop_break_iters(captured::AbstractString)
    m = match(r"Loop Break\s*:\s*time\s*=\s*[\d\.]+,\s*i\s*=\s*(\d+)", captured)
    return m === nothing ? -1 : parse(Int, m.captures[1])
end

# ---------------------------------------------------------------------------
# Pipeline runners
# ---------------------------------------------------------------------------

"""
Run TPO's heuristic pipeline and return per-step metrics plus the final
full-instance solution (needed for cross-package feasibility checking).
"""
function _run_tpo(instance, ls_limit::Real)
    local filtering_sol, sub
    filter_time = @elapsed begin
        filtering_sol = TPO.lower_bound_filtering(instance)
        sub = TPO.extract_filtered_instance(instance, filtering_sol)
    end

    local candidates, chosen
    init_time = @elapsed begin
        candidates = TPO.mix_greedy_and_lower_bound(sub)
        chosen = TPO.choose_best_feasible(
            [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
        )
    end

    full_cost(sub_sol) = TPO.cost_with_nodes(
        TPO.merge_solutions(filtering_sol, sub_sol, instance, sub), instance
    )
    greedy_cost = full_cost(candidates.greedy)
    lb_cost = full_cost(candidates.lower_bound)
    mixed_cost = full_cost(candidates.mixed)

    init_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    init_cost = TPO.cost_with_nodes(init_full, instance)
    init_feasible = TPO.is_feasible(init_full, instance)

    ls_iters = 0
    ls_saved = 0.0
    ls_time = 0.0
    if ls_limit > 0
        local ls_result
        ls_time = @elapsed ls_result = TPO.local_search!(
            chosen, sub; time_limit=ls_limit
        )
        ls_iters = ls_result.n_iter
        ls_saved = ls_result.saved
    end

    ls_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    ls_cost = TPO.cost_with_nodes(ls_full, instance)
    ls_feasible = TPO.is_feasible(ls_full, instance)

    return (;
        filter_time, init_time,
        greedy_cost, lb_cost, mixed_cost,
        init_cost, init_feasible,
        ls_cost, ls_time, ls_feasible,
        ls_iters, ls_saved,
        full_solution=ls_full,
    )
end

"""
Run STP's heuristic pipeline and return per-step metrics.
"""
function _run_stp(instance, ls_limit::Real; ils_limit::Real=0)
    local filtering_sol, sub
    filter_time = @elapsed begin
        filtering_sol = STP.Solution(instance)
        STP.lower_bound_filtering!(filtering_sol, instance)
        sub = STP.extract_filtered_instance(instance, filtering_sol)
        sub = STP.add_properties(sub, STP.tentative_first_fit, Int[])
    end

    local mix_sol, greedy_sol, lb_sol, chosen
    init_time = @elapsed begin
        mix_sol = STP.Solution(sub)
        greedy_sol, lb_sol = STP.mix_greedy_and_lower_bound!(mix_sol, sub)
        chosen = _stp_choose_best(mix_sol, greedy_sol, lb_sol, sub)
    end

    full_cost(sub_sol) = STP.compute_cost(
        instance, STP.merge_solutions(sub_sol, filtering_sol, instance, sub)
    )
    greedy_cost = full_cost(greedy_sol)
    lb_cost = full_cost(lb_sol)
    mixed_cost = full_cost(mix_sol)

    init_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    init_cost = STP.compute_cost(instance, init_full)
    init_feasible = STP.is_feasible(instance, init_full)

    ls_iters = 0
    ls_saved = 0.0
    ls_time = 0.0
    if ls_limit > 0
        pre_ls_cost = STP.compute_cost(sub, chosen)
        captured = ""
        ls_time = mktemp() do path, io
            t = @elapsed redirect_stdout(io) do
                STP.local_search!(chosen, sub; timeLimit=ls_limit, verbose=false)
            end
            flush(io)
            captured = read(path, String)
            return t
        end
        ls_iters = _parse_stp_loop_break_iters(captured)
        post_ls_cost = STP.compute_cost(sub, chosen)
        ls_saved = pre_ls_cost - post_ls_cost
    end

    ls_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    ls_cost = STP.compute_cost(instance, ls_full)
    ls_feasible = STP.is_feasible(instance, ls_full)

    ils_cost = NaN
    if ils_limit > 0
        pert_limit = round(Int, min(180.0, ils_limit / 5))
        inner_ls = round(Int, min(2700.0, ils_limit))
        mktemp() do path, io
            redirect_stdout(io) do
                STP.ILS!(
                    chosen, sub;
                    timeLimit=Int(ils_limit),
                    perturbTimeLimit=pert_limit,
                    lsTimeLimit=inner_ls,
                    verbose=false,
                    solName="",
                    timedelta=inner_ls,
                )
            end
        end
        ils_cost = full_cost(chosen)
    end

    return (;
        filter_time, init_time,
        greedy_cost, lb_cost, mixed_cost,
        init_cost, init_feasible,
        ls_cost, ls_time, ls_feasible,
        ls_iters, ls_saved,
        ils_cost,
    )
end

"""
Translate the TPO solution into STP's representation and check feasibility.
Returns the number of bundles translated, feasibility flag, and cost agreement.
"""
function _cross_validate(tpo_full_sol, tpo_instance, stp_instance)
    translated = _translate_tpo_to_stp(tpo_full_sol, tpo_instance, stp_instance)
    n_translated = length(translated)
    n_total = length(tpo_instance.bundles)
    tpo_in_stp = _build_stp_from_translated(translated, stp_instance)
    feasible = STP.is_feasible(stp_instance, tpo_in_stp)
    recomputed_cost = STP.compute_cost(stp_instance, tpo_in_stp)
    tpo_cost = TPO.cost_with_nodes(tpo_full_sol, tpo_instance)
    cost_ratio = tpo_cost == 0 ? NaN : recomputed_cost / tpo_cost
    return (; n_translated, n_total, feasible, cost_ratio)
end

# ---------------------------------------------------------------------------
# Main comparison
# ---------------------------------------------------------------------------

function compare_instance(name::String, ls_limit::Real; ils_limit::Real=0)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")

    local tpo_instance
    tpo_build_time = @elapsed begin
        (; nodes, arcs, commodities) = parse_inbound_instance(
            nodes_file, legs_file, com_file
        )
        tpo_instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    end

    local stp_instance
    stp_build_time = @elapsed begin
        stp_instance = STP.read_instance(nodes_file, legs_file, com_file)
        stp_instance = STP.add_properties(stp_instance, STP.tentative_first_fit, Int[])
    end

    @info "Running TPO pipeline" instance = name
    tpo = _run_tpo(tpo_instance, ls_limit)
    @info "Running STP pipeline" instance = name
    stp = _run_stp(stp_instance, ls_limit; ils_limit)
    @info "Cross-validating" instance = name
    cv = _cross_validate(tpo.full_solution, tpo_instance, stp_instance)

    return (;
        n_bundles=length(tpo_instance.bundles),
        tpo_build_time, stp_build_time,
        tpo_filter_time=tpo.filter_time, stp_filter_time=stp.filter_time,
        tpo_init_time=tpo.init_time, stp_init_time=stp.init_time,
        tpo_greedy_cost=tpo.greedy_cost, stp_greedy_cost=stp.greedy_cost,
        tpo_lb_cost=tpo.lb_cost, stp_lb_cost=stp.lb_cost,
        tpo_mixed_cost=tpo.mixed_cost, stp_mixed_cost=stp.mixed_cost,
        tpo_init_cost=tpo.init_cost, stp_init_cost=stp.init_cost,
        tpo_init_feasible=tpo.init_feasible, stp_init_feasible=stp.init_feasible,
        tpo_ls_cost=tpo.ls_cost, stp_ls_cost=stp.ls_cost,
        tpo_ls_time=tpo.ls_time, stp_ls_time=stp.ls_time,
        tpo_ls_feasible=tpo.ls_feasible, stp_ls_feasible=stp.ls_feasible,
        tpo_ls_iters=tpo.ls_iters, stp_ls_iters=stp.ls_iters,
        tpo_ls_saved=tpo.ls_saved, stp_ls_saved=stp.ls_saved,
        stp_ils_cost=stp.ils_cost,
        cross_translated=cv.n_translated,
        cross_total=cv.n_total,
        cross_feasible=cv.feasible,
        cross_cost_ratio=cv.cost_ratio,
    )
end

# ---------------------------------------------------------------------------
# Result formatting
# ---------------------------------------------------------------------------

_safe_div(a, b) = b == 0 ? NaN : a / b

"Build a single-row DataFrame from one instance's comparison results."
function build_row(name::String, r)
    tpo_ls_ips = round(_safe_div(r.tpo_ls_iters, r.tpo_ls_time); digits=1)
    stp_ls_ips = round(_safe_div(r.stp_ls_iters, r.stp_ls_time); digits=1)
    row = DataFrame(;
        instance=[name],
        n_bundles=[r.n_bundles],
        tpo_build_s=[round(r.tpo_build_time; digits=2)],
        stp_build_s=[round(r.stp_build_time; digits=2)],
        tpo_filter_s=[round(r.tpo_filter_time; digits=2)],
        stp_filter_s=[round(r.stp_filter_time; digits=2)],
        tpo_init_s=[round(r.tpo_init_time; digits=2)],
        stp_init_s=[round(r.stp_init_time; digits=2)],
        tpo_greedy_cost=[round(r.tpo_greedy_cost; digits=1)],
        stp_greedy_cost=[round(r.stp_greedy_cost; digits=1)],
        greedy_cost_ratio=[round(r.tpo_greedy_cost / r.stp_greedy_cost; digits=4)],
        tpo_lb_cost=[round(r.tpo_lb_cost; digits=1)],
        stp_lb_cost=[round(r.stp_lb_cost; digits=1)],
        lb_cost_ratio=[round(r.tpo_lb_cost / r.stp_lb_cost; digits=4)],
        tpo_mixed_cost=[round(r.tpo_mixed_cost; digits=1)],
        stp_mixed_cost=[round(r.stp_mixed_cost; digits=1)],
        mixed_cost_ratio=[round(r.tpo_mixed_cost / r.stp_mixed_cost; digits=4)],
        tpo_init_cost=[round(r.tpo_init_cost; digits=1)],
        stp_init_cost=[round(r.stp_init_cost; digits=1)],
        init_cost_ratio=[round(r.tpo_init_cost / r.stp_init_cost; digits=4)],
        tpo_ls_cost=[round(r.tpo_ls_cost; digits=1)],
        stp_ls_cost=[round(r.stp_ls_cost; digits=1)],
        ls_cost_ratio=[round(r.tpo_ls_cost / r.stp_ls_cost; digits=4)],
        tpo_ls_s=[round(r.tpo_ls_time; digits=2)],
        stp_ls_s=[round(r.stp_ls_time; digits=2)],
        tpo_ls_iters=[r.tpo_ls_iters],
        stp_ls_iters=[r.stp_ls_iters],
        tpo_ls_iter_per_s=[tpo_ls_ips],
        stp_ls_iter_per_s=[stp_ls_ips],
        tpo_ls_saved=[round(r.tpo_ls_saved; digits=1)],
        stp_ls_saved=[round(r.stp_ls_saved; digits=1)],
        tpo_init_feasible=[r.tpo_init_feasible],
        stp_init_feasible=[r.stp_init_feasible],
        tpo_ls_feasible=[r.tpo_ls_feasible],
        stp_ls_feasible=[r.stp_ls_feasible],
        cross_translated=[r.cross_translated],
        cross_total=[r.cross_total],
        cross_feasible=[r.cross_feasible],
        cross_cost_ratio=[round(r.cross_cost_ratio; digits=6)],
    )
    if INCLUDE_ILS
        row.stp_ils_cost = [round(r.stp_ils_cost; digits=1)]
        row.ils_ls_ratio = [
            isnan(r.stp_ils_cost) ? NaN : round(r.stp_ils_cost / r.stp_ls_cost; digits=6)
        ]
    end
    return row
end

"Print a concise console summary of one instance's results."
function print_row(name::String, r)
    @printf("\n%-12s  (%d bundles)\n", name, r.n_bundles)
    @printf("  %-14s %14s %14s %10s\n", "metric", "TPO", "STP", "TPO/STP")
    @printf(
        "  %-14s %14.2f %14.2f %10.2f\n",
        "build s", r.tpo_build_time, r.stp_build_time,
        r.tpo_build_time / r.stp_build_time,
    )
    @printf(
        "  %-14s %14.2f %14.2f %10.2f\n",
        "filter s", r.tpo_filter_time, r.stp_filter_time,
        r.tpo_filter_time / r.stp_filter_time,
    )
    @printf(
        "  %-14s %14.2f %14.2f %10.2f\n",
        "init s", r.tpo_init_time, r.stp_init_time,
        r.tpo_init_time / r.stp_init_time,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "greedy cost", r.tpo_greedy_cost, r.stp_greedy_cost,
        r.tpo_greedy_cost / r.stp_greedy_cost,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "LB cost", r.tpo_lb_cost, r.stp_lb_cost,
        r.tpo_lb_cost / r.stp_lb_cost,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "mixed cost", r.tpo_mixed_cost, r.stp_mixed_cost,
        r.tpo_mixed_cost / r.stp_mixed_cost,
    )
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "init cost", r.tpo_init_cost, r.stp_init_cost,
        r.tpo_init_cost / r.stp_init_cost,
    )
    if r.tpo_ls_iters > 0 || r.stp_ls_iters > 0
        @printf(
            "  %-14s %14d %14d %10.3f\n",
            "LS iters", r.tpo_ls_iters, r.stp_ls_iters,
            _safe_div(r.tpo_ls_iters, max(r.stp_ls_iters, 1)),
        )
        tpo_ips = _safe_div(r.tpo_ls_iters, r.tpo_ls_time)
        stp_ips = _safe_div(r.stp_ls_iters, r.stp_ls_time)
        @printf(
            "  %-14s %14.1f %14.1f %10.3f\n",
            "LS iter/s", tpo_ips, stp_ips,
            _safe_div(tpo_ips, max(stp_ips, 1e-9)),
        )
        @printf("  %-14s %14.1f %14.1f\n", "LS saved", r.tpo_ls_saved, r.stp_ls_saved)
    end
    @printf(
        "  %-14s %14.1f %14.1f %10.4f\n",
        "LS cost", r.tpo_ls_cost, r.stp_ls_cost,
        r.tpo_ls_cost / r.stp_ls_cost,
    )
    if INCLUDE_ILS && !isnan(r.stp_ils_cost)
        @printf(
            "  %-14s %14s %14.1f %10.6f\n",
            "ILS cost", "n/a", r.stp_ils_cost,
            r.stp_ils_cost / r.stp_ls_cost,
        )
    end
    @printf(
        "  %-14s %d / %d  feasible=%s  cost_agreement=%.6f\n",
        "cross-valid", r.cross_translated, r.cross_total,
        r.cross_feasible, r.cross_cost_ratio,
    )
    if !(r.tpo_ls_feasible && r.stp_ls_feasible)
        @printf(
            "  WARNING infeasible: tpo_ls=%s stp_ls=%s\n",
            r.tpo_ls_feasible, r.stp_ls_feasible,
        )
    end
    return nothing
end

"Render the full results DataFrame as a structured markdown report."
function write_markdown(df::DataFrame, path::String)
    open(path, "w") do io
        println(io, "# TPO vs STP Comparison")
        println(io)
        println(io, "Generated: ", Dates.now())
        println(io)
        println(io, "Ratios are TPO / STP.")
        println(io, "< 1 means TPO is cheaper or faster.")
        println(io)

        # Cost quality table.
        println(io, "## Cost Quality (TPO / STP ratio at each step)")
        println(io)
        println(io, "| Instance | Bundles | Greedy | LB | Mixed | Init | LS |")
        println(io, "|---|---|---|---|---|---|---|")
        for row in eachrow(df)
            @printf(
                io,
                "| %s | %d | %.4f | %.4f | %.4f | %.4f | %.4f |\n",
                row.instance, row.n_bundles,
                row.greedy_cost_ratio, row.lb_cost_ratio,
                row.mixed_cost_ratio, row.init_cost_ratio,
                row.ls_cost_ratio,
            )
        end
        println(io)

        if nrow(df) > 0
            init_gm = exp(sum(log, df.init_cost_ratio) / nrow(df))
            ls_gm = exp(sum(log, df.ls_cost_ratio) / nrow(df))
            @printf(io, "Geometric-mean init-cost ratio: **%.4f**\n", init_gm)
            println(io)
            @printf(io, "Geometric-mean LS-cost ratio: **%.4f**\n", ls_gm)
            println(io)
        end

        # Timing table.
        println(io, "## Timing (seconds)")
        println(io)
        println(
            io,
            "| Instance | TPO build | STP build | TPO filter | STP filter | TPO init | STP init |",
        )
        println(io, "|---|---|---|---|---|---|---|")
        for row in eachrow(df)
            @printf(
                io,
                "| %s | %.2f | %.2f | %.2f | %.2f | %.2f | %.2f |\n",
                row.instance,
                row.tpo_build_s, row.stp_build_s,
                row.tpo_filter_s, row.stp_filter_s,
                row.tpo_init_s, row.stp_init_s,
            )
        end
        println(io)

        # LS throughput table.
        ls_rows = filter(
            row -> row.tpo_ls_iters > 0 || row.stp_ls_iters > 0, collect(eachrow(df))
        )
        if !isempty(ls_rows)
            println(io, "## Local Search Throughput")
            println(io)
            println(
                io,
                "| Instance | TPO iters | STP iters | TPO iter/s | STP iter/s | Ratio |",
            )
            println(io, "|---|---|---|---|---|---|")
            for row in ls_rows
                ratio = _safe_div(
                    row.tpo_ls_iter_per_s, max(row.stp_ls_iter_per_s, 1e-9)
                )
                @printf(
                    io,
                    "| %s | %d | %d | %.1f | %.1f | %.3f |\n",
                    row.instance,
                    row.tpo_ls_iters, row.stp_ls_iters,
                    row.tpo_ls_iter_per_s, row.stp_ls_iter_per_s,
                    ratio,
                )
            end
            println(io)
        end

        # Cross-validation table.
        if hasproperty(df, :cross_feasible)
            println(io, "## Cross-Package Validation")
            println(io)
            println(
                io,
                "| Instance | Translated | Total | Feasible in STP | Cost Agreement |",
            )
            println(io, "|---|---|---|---|---|")
            for row in eachrow(df)
                @printf(
                    io,
                    "| %s | %d | %d | %s | %.6f |\n",
                    row.instance,
                    row.cross_translated, row.cross_total,
                    row.cross_feasible, row.cross_cost_ratio,
                )
            end
            println(io)
        end

        # ILS section.
        if INCLUDE_ILS && hasproperty(df, :stp_ils_cost)
            println(io, "## STP ILS vs LS")
            println(io)
            println(io, "| Instance | STP LS cost | STP ILS cost | ILS / LS |")
            println(io, "|---|---|---|---|")
            for row in eachrow(df)
                isnan(row.stp_ils_cost) && continue
                @printf(
                    io,
                    "| %s | %.1f | %.1f | %.6f |\n",
                    row.instance,
                    row.stp_ls_cost, row.stp_ils_cost,
                    row.ils_ls_ratio,
                )
            end
            println(io)
        end

        # Feasibility warnings.
        infeasible = filter(
            row -> !(row.tpo_ls_feasible && row.stp_ls_feasible), collect(eachrow(df))
        )
        if !isempty(infeasible)
            println(io, "## Feasibility Warnings")
            println(io)
            for row in infeasible
                @printf(
                    io,
                    "- **%s**: tpo_ls=%s, stp_ls=%s\n",
                    row.instance,
                    row.tpo_ls_feasible, row.stp_ls_feasible,
                )
            end
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

"""
Run the comparison over all configured instances.

Writes CSV and markdown after each instance so partial progress survives a
crash. Pass `ls_limit_override` to use the same LS budget for every instance
(useful for quick passes).
"""
function compare_all(; ls_limit_override::Union{Nothing,Real}=nothing)
    isdir(OUTPUT_DIR) || mkpath(OUTPUT_DIR)
    csv_path = joinpath(OUTPUT_DIR, "comparison.csv")
    md_path = joinpath(OUTPUT_DIR, "comparison.md")

    df = if SKIP_EXISTING && isfile(csv_path)
        loaded = DataFrame(CSV.File(csv_path))
        if "greedy_cost_ratio" in names(loaded)
            loaded
        else
            @warn "Existing CSV uses old schema, starting fresh"
            DataFrame()
        end
    else
        DataFrame()
    end
    done = nrow(df) > 0 ? Set(string.(df.instance)) : Set{String}()

    if !isempty(INSTANCES)
        @info "JIT warmup on $(first(INSTANCES)) (timings discarded)"
        try
            compare_instance(first(INSTANCES), 1)
        catch err
            @warn "Warmup failed" exception = err
        end
        GC.gc()
    end

    for name in INSTANCES
        if name in done
            @info "Skipping $name (already in CSV)"
            continue
        end
        ls_limit = ls_limit_override === nothing ? _ls_limit(name) : ls_limit_override
        ils_limit = INCLUDE_ILS ? _ils_limit(name) : 0
        @info "Running $name" ls_limit ils_limit
        local result
        try
            result = compare_instance(name, ls_limit; ils_limit)
            GC.gc()
        catch err
            @error "Instance $name failed, skipping" exception = (err, catch_backtrace())
            continue
        end
        print_row(name, result)
        df = vcat(df, build_row(name, result); cols=:union)
        CSV.write(csv_path, df)
        write_markdown(df, md_path)
        @info "Wrote results through $name"
    end

    println("\n", "="^60)
    println("Comparison complete. Results in:")
    println("  ", csv_path)
    println("  ", md_path)
    return df
end

if abspath(PROGRAM_FILE) == @__FILE__
    compare_all()
end
