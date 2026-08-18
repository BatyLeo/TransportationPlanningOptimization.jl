using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using ShipperTransportationPlanning
const STP = ShipperTransportationPlanning
using Dates
using MetaGraphsNext: MetaGraphsNext, label_for, labels, code_for
using SparseArrays: SparseArrays

include(joinpath(@__DIR__, "..", "test", "Inbound.jl"))
using .Inbound: parse_inbound_instance

const DATA_DIR = joinpath(@__DIR__, "..", "test", "public")
const LS_TIME = 60

# ── Translation helpers (from compare_to_shipper.jl) ──

function stp_account_to_node(stp_instance)
    g = stp_instance.networkGraph.graph
    out = Dict{String,STP.NetworkNode}()
    for label in MetaGraphsNext.labels(g)
        node = g[label]
        out[node.account] = node
    end
    return out
end

function tpo_to_stp_code(tpo_code::Int, tpo_instance, stp_instance, stp_node_by_account)
    label = MetaGraphsNext.label_for(tpo_instance.travel_time_graph.graph, tpo_code)
    sid, tau = label
    haskey(stp_node_by_account, sid) || return nothing
    node = stp_node_by_account[sid]
    return get(stp_instance.travelTimeGraph.hashToIdx, hash(tau, node.hash), nothing)
end

function translate_tpo_solution_to_stp(tpo_sol, tpo_instance, stp_instance)
    stp_node_by_account = stp_account_to_node(stp_instance)
    out = Dict{Tuple{String,String},Vector{Int}}()
    for (i, bundle) in enumerate(tpo_instance.bundles)
        path = tpo_sol.bundle_paths[i]
        isempty(path) && continue
        translated = Int[]
        ok = true
        for code in path
            mapped = tpo_to_stp_code(code, tpo_instance, stp_instance, stp_node_by_account)
            if mapped === nothing
                label = MetaGraphsNext.label_for(tpo_instance.travel_time_graph.graph, code)
                @warn "TPO->STP translation failure" bundle_idx = i label
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

function build_stp_solution_from_translated_paths(
    paths_by_od::Dict{Tuple{String,String},Vector{Int}}, stp_instance
)
    sol = STP.Solution(stp_instance)
    for (i, bundle) in enumerate(stp_instance.bundles)
        key = (bundle.supplier.account, bundle.customer.account)
        haskey(paths_by_od, key) || continue
        STP.update_solution!(sol, stp_instance, bundle, copy(paths_by_od[key]); sorted=true)
    end
    return sol
end

function load_instance_pair(name::String)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    commodities_file = joinpath(DATA_DIR, "$(name)_commodities.csv")

    (; nodes, arcs, commodities) = parse_inbound_instance(
        nodes_file, legs_file, commodities_file
    )
    tpo_instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    stp_instance = STP.read_instance(nodes_file, legs_file, commodities_file)
    return (; tpo_instance, stp_instance)
end

# ── Main comparison ──

function compare_full_pipeline(name::String)
    println("\n", "="^70)
    println("  FULL PIPELINE COMPARISON: $name")
    println("="^70)

    (; tpo_instance, stp_instance) = load_instance_pair(name)
    stp_instance = STP.add_properties(stp_instance, STP.tentative_first_fit, Int[])

    println("\nInstance: $(TPO.bundle_count(tpo_instance)) bundles, " *
            "$(TPO.order_count(tpo_instance)) orders, " *
            "$(TPO.commodity_count(tpo_instance)) commodities")

    # ── Step 1: Filtering ──
    println("\n--- Step 1: Lower-bound filtering ---")

    tpo_filter_time = @elapsed tpo_filtering_sol = TPO.lower_bound_filtering(tpo_instance)
    tpo_filter_cost = TPO.cost_with_nodes(tpo_filtering_sol, tpo_instance)
    tpo_filter_feasible = TPO.is_feasible(tpo_filtering_sol, tpo_instance)

    stp_filter_time = @elapsed begin
        stp_filtering_sol = STP.Solution(stp_instance)
        STP.lower_bound_filtering!(stp_filtering_sol, stp_instance)
    end
    stp_filter_cost = STP.compute_cost(stp_instance, stp_filtering_sol)
    stp_filter_feasible = STP.is_feasible(stp_instance, stp_filtering_sol)

    println("  TPO: cost=$(round(tpo_filter_cost; digits=1)), " *
            "feasible=$tpo_filter_feasible, time=$(round(tpo_filter_time; digits=2))s")
    println("  STP: cost=$(round(stp_filter_cost; digits=1)), " *
            "feasible=$stp_filter_feasible, time=$(round(stp_filter_time; digits=2))s")
    println("  Ratio (TPO/STP): $(round(tpo_filter_cost / stp_filter_cost; digits=4))")

    # ── Step 2: Extract sub-instance ──
    println("\n--- Step 2: Extract filtered sub-instance ---")

    tpo_sub = TPO.extract_filtered_instance(tpo_instance, tpo_filtering_sol)
    stp_sub = STP.extract_filtered_instance(stp_instance, stp_filtering_sol)
    stp_sub = STP.add_properties(stp_sub, STP.tentative_first_fit, Int[])

    tpo_filtered_count = count(
        i -> !isempty(tpo_filtering_sol.bundle_paths[i]),
        1:TPO.bundle_count(tpo_instance),
    )
    stp_filtered_count = count(
        i -> !isempty(stp_filtering_sol.bundlePaths[i]),
        1:length(stp_instance.bundles),
    )
    println("  TPO: $(TPO.bundle_count(tpo_sub)) bundles in sub-instance " *
            "($tpo_filtered_count filtered to direct)")
    println("  STP: $(length(stp_sub.bundles)) bundles in sub-instance " *
            "($stp_filtered_count filtered to direct)")

    # ── Step 3: Mix construction on sub-instance ──
    println("\n--- Step 3: Mix construction (greedy + LB + mixed) ---")

    tpo_mix_time = @elapsed tpo_candidates = TPO.mix_greedy_and_lower_bound(tpo_sub)
    tpo_chosen = TPO.choose_best_feasible(
        [tpo_candidates.mixed, tpo_candidates.greedy, tpo_candidates.lower_bound],
        tpo_sub,
    )

    tpo_greedy_full = TPO.merge_solutions(
        tpo_filtering_sol, tpo_candidates.greedy, tpo_instance, tpo_sub
    )
    tpo_lb_full = TPO.merge_solutions(
        tpo_filtering_sol, tpo_candidates.lower_bound, tpo_instance, tpo_sub
    )
    tpo_mixed_full = TPO.merge_solutions(
        tpo_filtering_sol, tpo_candidates.mixed, tpo_instance, tpo_sub
    )
    tpo_chosen_full = TPO.merge_solutions(
        tpo_filtering_sol, tpo_chosen, tpo_instance, tpo_sub
    )

    tpo_greedy_cost = TPO.cost_with_nodes(tpo_greedy_full, tpo_instance)
    tpo_lb_cost = TPO.cost_with_nodes(tpo_lb_full, tpo_instance)
    tpo_mixed_cost = TPO.cost_with_nodes(tpo_mixed_full, tpo_instance)
    tpo_chosen_cost = TPO.cost_with_nodes(tpo_chosen_full, tpo_instance)

    stp_mix_time = @elapsed begin
        stp_mix_sol = STP.Solution(stp_sub)
        stp_greedy_sol, stp_lb_sol = STP.mix_greedy_and_lower_bound!(stp_mix_sol, stp_sub)
    end
    stp_candidates = [stp_mix_sol, stp_greedy_sol, stp_lb_sol]
    stp_feasible_candidates = filter(s -> STP.is_feasible(stp_sub, s), stp_candidates)
    stp_costs = [STP.compute_cost(stp_sub, s) for s in stp_feasible_candidates]
    stp_chosen = STP.solution_deepcopy(stp_feasible_candidates[argmin(stp_costs)], stp_sub)

    stp_greedy_full = STP.merge_solutions(stp_greedy_sol, stp_filtering_sol, stp_instance, stp_sub)
    stp_lb_full = STP.merge_solutions(stp_lb_sol, stp_filtering_sol, stp_instance, stp_sub)
    stp_mixed_full = STP.merge_solutions(stp_mix_sol, stp_filtering_sol, stp_instance, stp_sub)
    stp_chosen_full = STP.merge_solutions(stp_chosen, stp_filtering_sol, stp_instance, stp_sub)

    stp_greedy_cost = STP.compute_cost(stp_instance, stp_greedy_full)
    stp_lb_cost = STP.compute_cost(stp_instance, stp_lb_full)
    stp_mixed_cost = STP.compute_cost(stp_instance, stp_mixed_full)
    stp_chosen_cost = STP.compute_cost(stp_instance, stp_chosen_full)

    println("  TPO greedy:  $(round(tpo_greedy_cost; digits=1))")
    println("  TPO LB:      $(round(tpo_lb_cost; digits=1))")
    println("  TPO mixed:   $(round(tpo_mixed_cost; digits=1))")
    println("  TPO chosen:  $(round(tpo_chosen_cost; digits=1))  (time=$(round(tpo_mix_time; digits=2))s)")
    println()
    println("  STP greedy:  $(round(stp_greedy_cost; digits=1))")
    println("  STP LB:      $(round(stp_lb_cost; digits=1))")
    println("  STP mixed:   $(round(stp_mixed_cost; digits=1))")
    println("  STP chosen:  $(round(stp_chosen_cost; digits=1))  (time=$(round(stp_mix_time; digits=2))s)")
    println()
    println("  Construction ratio (TPO/STP): $(round(tpo_chosen_cost / stp_chosen_cost; digits=4))")

    # ── Step 4: Local search on sub-instance ──
    println("\n--- Step 4: Local search ($(LS_TIME)s) on sub-instance ---")

    tpo_ls_time = @elapsed TPO.local_search!(tpo_chosen, tpo_sub; time_limit=LS_TIME)
    tpo_ls_full = TPO.merge_solutions(tpo_filtering_sol, tpo_chosen, tpo_instance, tpo_sub)
    tpo_ls_cost = TPO.cost_with_nodes(tpo_ls_full, tpo_instance)
    tpo_ls_feasible = TPO.is_feasible(tpo_ls_full, tpo_instance)

    stp_ls_time = @elapsed STP.local_search!(stp_chosen, stp_sub; timeLimit=LS_TIME, verbose=false)
    stp_ls_full = STP.merge_solutions(stp_chosen, stp_filtering_sol, stp_instance, stp_sub)
    stp_ls_cost = STP.compute_cost(stp_instance, stp_ls_full)
    stp_ls_feasible = STP.is_feasible(stp_instance, stp_ls_full)

    println("  TPO: cost=$(round(tpo_ls_cost; digits=1)), " *
            "feasible=$tpo_ls_feasible, time=$(round(tpo_ls_time; digits=2))s")
    println("  STP: cost=$(round(stp_ls_cost; digits=1)), " *
            "feasible=$stp_ls_feasible, time=$(round(stp_ls_time; digits=2))s")
    println("  Post-LS ratio (TPO/STP): $(round(tpo_ls_cost / stp_ls_cost; digits=4))")

    # ── Cross-package feasibility check ──
    println("\n--- Cross-package feasibility check ---")

    translated = translate_tpo_solution_to_stp(tpo_ls_full, tpo_instance, stp_instance)
    n_translated = length(translated)
    n_total = TPO.bundle_count(tpo_instance)
    println("  Translated $n_translated / $n_total bundle paths from TPO to STP")

    tpo_in_stp = build_stp_solution_from_translated_paths(translated, stp_instance)
    stp_feasible = STP.is_feasible(stp_instance, tpo_in_stp)
    stp_recomputed_cost = STP.compute_cost(stp_instance, tpo_in_stp)

    println("  TPO solution feasible in STP: $stp_feasible")
    println("  TPO cost (native):     $(round(tpo_ls_cost; digits=1))")
    println("  TPO cost (via STP):    $(round(stp_recomputed_cost; digits=1))")
    println("  Cost agreement ratio:  $(round(stp_recomputed_cost / tpo_ls_cost; digits=6))")

    # ── Summary ──
    println("\n--- SUMMARY ---")
    println("  Step             TPO cost       STP cost       Ratio(TPO/STP)")
    println("  Filtering        $(lpad(round(tpo_filter_cost; digits=0), 12))  $(lpad(round(stp_filter_cost; digits=0), 12))  $(round(tpo_filter_cost/stp_filter_cost; digits=4))")
    println("  Construction     $(lpad(round(tpo_chosen_cost; digits=0), 12))  $(lpad(round(stp_chosen_cost; digits=0), 12))  $(round(tpo_chosen_cost/stp_chosen_cost; digits=4))")
    println("  Post-LS          $(lpad(round(tpo_ls_cost; digits=0), 12))  $(lpad(round(stp_ls_cost; digits=0), 12))  $(round(tpo_ls_cost/stp_ls_cost; digits=4))")
    println("  TPO feasible in STP: $stp_feasible")

    return nothing
end

for name in ["tiny", "small"]
    compare_full_pipeline(name)
end
