# TPO vs Hexaly: outbound performance and quality comparison.
#
# Parses the dataMVP outbound instance, runs TPO's heuristic pipeline, loads
# the Hexaly reference solution from result_NDO.csv, and prints a side-by-side
# comparison table (costs, gaps, timing, feasibility).
#
# Run with:
#   julia --project=scripts scripts/outbound/compare_outbound_to_hexaly.jl

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using Dates
using Printf
using CSV
using DataFrames
using MetaGraphsNext: code_for

include(joinpath(@__DIR__, "Outbound.jl"))
using .Outbound

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "outbound", "dataMVP")
const LS_TIME = 180

# ---------------------------------------------------------------------------
# Hexaly solution loader
# ---------------------------------------------------------------------------

"""
    load_hexaly_solution(instance, data_dir)

Read the Hexaly routing from `data_dir/output/result_NDO.csv`, find the
dominant route per (origin, destination, model) triple, and build a TPO
`Solution` by assigning each bundle to its dominant route path.

Returns `(; solution, hexaly_cost, matched, unmatched, path_failed)`.
`hexaly_cost` is Hexaly's own reported accounting total (hardcoded from the
reference output, not recomputed by TPO).
"""
function load_hexaly_solution(instance, data_dir::AbstractString)
    result_file = joinpath(data_dir, "output", "result_NDO.csv")
    if !isfile(result_file)
        @warn "Hexaly result file not found" path = result_file
        return nothing
    end

    df = DataFrame(CSV.File(result_file; decimal=','))

    # Parse routes: group by IDRoute, build path nodes + model + volume
    routes = Dict{
        Int,@NamedTuple{nodes::Vector{String}, model::String, volume::Float64}
    }()
    for sub in groupby(df, :IDRoute)
        sorted = sort(sub, :LegOrder)
        path_nodes = String[sorted[1, :OrigineLeg]]
        for r in eachrow(sorted)
            push!(path_nodes, r.DestinationLeg)
        end
        mod_str = sorted[1, :Modele]
        m = replace(mod_str, "mod_" => "")
        m = split(m, "&&")[1]
        rid = sorted[1, :IDRoute]
        routes[rid] = (nodes=path_nodes, model=String(m), volume=Float64(sorted[1, :Volume]))
    end

    # Dominant route per (origin, dest, model): the one with max volume
    od_dominant = Dict{Tuple{String,String,String},Int}()
    for (rid, r) in routes
        key = (r.nodes[1], r.nodes[end], r.model)
        if !haskey(od_dominant, key) || routes[od_dominant[key]].volume < r.volume
            od_dominant[key] = rid
        end
    end

    # Build TTG int-code path from string path
    graph = instance.travel_time_graph.graph
    function to_ttg_path(str_path::Vector{String})
        for tau_try in (0, 1)
            codes = Int[]
            ok = true
            for nid in str_path
                label = (nid, tau_try)
                if haskey(graph.vertex_properties, label)
                    push!(codes, code_for(graph, label))
                else
                    ok = false
                    break
                end
            end
            ok && return codes
        end
        return nothing
    end

    sol = TPO.Solution(instance)
    matched = 0
    unmatched = String[]
    path_failed = String[]

    for (bidx, bundle) in enumerate(instance.bundles)
        bmodel = string(bundle.orders[1].commodities[1].info.model)
        key = (bundle.origin_id, bundle.destination_id, bmodel)
        if !haskey(od_dominant, key)
            push!(unmatched, "$key")
            continue
        end
        rid = od_dominant[key]
        str_path = routes[rid].nodes
        int_path = to_ttg_path(str_path)
        if int_path === nothing
            push!(path_failed, "$(key) -> $(str_path) (no TTG codes)")
            continue
        end
        TPO.add_bundle_path!(sol, instance, bidx, int_path)
        matched += 1
    end

    return (; solution=sol, matched, unmatched, path_failed)
end

# ---------------------------------------------------------------------------
# Main comparison
# ---------------------------------------------------------------------------

function compare_outbound()
    println("=" ^ 60)
    println("  TPO vs Hexaly: Outbound Comparison (dataMVP)")
    println("=" ^ 60)

    # ── Parse and build ──
    println("\n--- Parsing instance ---")
    local nodes, arcs, commodities
    t_parse = @elapsed begin
        (; nodes, arcs, commodities) = Outbound.parse_dataMVP_instance(
            DATA_DIR; model_costs=true
        )
    end
    @printf(
        "  parse: %.1fs  nodes=%d arcs=%d commodities=%d\n",
        t_parse, length(nodes), length(arcs), length(commodities),
    )

    local instance
    t_build = @elapsed begin
        instance = Instance(
            nodes, arcs, commodities, Day(600);
            wrap_time=false,
            allow_multimodal=true,
            group_by=c -> c.info.model,
        )
    end
    @printf("  build: %.1fs  bundles=%d\n", t_build, bundle_count(instance))

    # ── TPO pipeline ──
    println("\n--- TPO pipeline ---")
    selector = CheapestMode()

    local sol
    t_greedy = @elapsed sol = greedy_heuristic(instance; mode_selector=selector)
    greedy_cost = cost(sol)
    @printf("  greedy: cost=%.0f  time=%.1fs\n", greedy_cost, t_greedy)

    local ls_info
    t_ls = @elapsed ls_info = local_search!(sol, instance, selector; time_limit=LS_TIME)
    ls_cost = cost(sol)
    @printf(
        "  local_search: cost=%.0f  time=%.1fs  iter=%d  saved=%.0f\n",
        ls_cost, t_ls, ls_info.n_iter, ls_info.saved,
    )

    ls_feasible = is_feasible(sol, instance; verbose=true)
    @printf("  feasible: %s\n", ls_feasible)

    # ── Load Hexaly solution ──
    println("\n--- Hexaly solution ---")
    hex = load_hexaly_solution(instance, DATA_DIR)
    if hex === nothing
        println("  Hexaly result file not found, skipping comparison.")
        return nothing
    end

    hex_cost_in_tpo = cost(hex.solution)
    hex_feasible = is_feasible(hex.solution, instance)
    @printf("  matched: %d / %d bundles\n", hex.matched, bundle_count(instance))
    if !isempty(hex.unmatched)
        @printf("  unmatched: %d  (examples: %s)\n",
            length(hex.unmatched), join(first(hex.unmatched, 3), ", "))
    end
    if !isempty(hex.path_failed)
        @printf("  path lookup failed: %d\n", length(hex.path_failed))
    end
    @printf("  cost (evaluated by TPO): %.0f\n", hex_cost_in_tpo)
    @printf("  feasible (in TPO): %s\n", hex_feasible)

    # ── Comparison table ──
    println("\n", "=" ^ 60)
    println("  SUMMARY")
    println("=" ^ 60)

    gap_greedy = 100.0 * (greedy_cost - hex_cost_in_tpo) / hex_cost_in_tpo
    gap_ls = 100.0 * (ls_cost - hex_cost_in_tpo) / hex_cost_in_tpo

    @printf("\n  %-30s %16s %10s\n", "Metric", "Value", "Gap")
    @printf("  %-30s %16s %10s\n", "-" ^ 30, "-" ^ 16, "-" ^ 10)
    @printf("  %-30s %16.0f\n", "Hexaly cost (in TPO)", hex_cost_in_tpo)
    @printf("  %-30s %16.0f %+9.2f%%\n", "TPO greedy", greedy_cost, gap_greedy)
    @printf("  %-30s %16.0f %+9.2f%%\n", "TPO greedy + LS ($(LS_TIME)s)", ls_cost, gap_ls)
    println()

    @printf("  %-30s %16s\n", "Metric", "Value")
    @printf("  %-30s %16s\n", "-" ^ 30, "-" ^ 16)
    @printf("  %-30s %16.1f s\n", "Parse time", t_parse)
    @printf("  %-30s %16.1f s\n", "Build time", t_build)
    @printf("  %-30s %16.1f s\n", "Greedy time", t_greedy)
    @printf("  %-30s %16.1f s\n", "LS time", t_ls)
    @printf("  %-30s %16d\n", "LS iterations", ls_info.n_iter)
    @printf("  %-30s %16.0f\n", "LS cost saved", ls_info.saved)
    @printf("  %-30s %16s\n", "TPO feasible", ls_feasible)
    @printf("  %-30s %16s\n", "Hexaly feasible (in TPO)", hex_feasible)
    @printf("  %-30s %16d / %d\n", "Hexaly bundles matched", hex.matched, bundle_count(instance))
    println()

    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    compare_outbound()
end
