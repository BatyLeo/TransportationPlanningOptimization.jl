# Diagnostic: lower-bound cost decomposition between TPO and STP.
#
# Loads the `small` inbound instance, runs both packages' `lower_bound!`, finds
# the first bundle where TPO and STP pick different path lengths, and dumps
# the per-arc transport-cost contribution from each package on both candidate
# paths (direct and multi-hop). Used to localize cost-model divergences.
#
# History:
# - Originally identified the "STP uses per-order `ceil` on direct arcs, TPO
#   uses fractional volume/capacity" gap. That gap is now fixed (see
#   `src/algorithms/cost_matrix_update.jl` direct-arc dispatch). After the
#   fix, TPO and STP make the same path choice on the previously-diverging
#   bundle, so the script may report "no divergence found" on `small`.
# - The remaining cross-package LB cost gap (~50% on tiny, ~2% on small)
#   comes from STP's `volume_stock_cost` term (stock + carbon + node platform
#   cost), which TPO does not model. Re-run this script after adding stock
#   costs to verify those terms agree across packages.
#
# Run from the package root with:
#   julia --project=test -e 'include("test/diag_lb_gap.jl")'
#
# Not included from runtests.jl (this is a diagnostic, not a regression test).
# It mutates no source files.

using TransportationPlanningOptimization
using ShipperTransportationPlanning
using Dates
using Graphs
using MetaGraphsNext: label_for
using SparseArrays
using Printf

const TPO = TransportationPlanningOptimization
const STP = ShipperTransportationPlanning

# Reuse the parser used by the comparison tests
isdefined(Main, :Inbound) || include(joinpath(@__DIR__, "Inbound.jl"))
using .Inbound: parse_inbound_instance

datadir = joinpath(@__DIR__, "public")
nodes_file = joinpath(datadir, "small_nodes.csv")
legs_file = joinpath(datadir, "small_legs.csv")
commodities_file = joinpath(datadir, "small_commodities.csv")

(; nodes, arcs, commodities) = parse_inbound_instance(
    nodes_file, legs_file, commodities_file
)
tpo_instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

stp_instance_raw = STP.read_instance(nodes_file, legs_file, commodities_file)
stp_instance = STP.add_properties(stp_instance_raw, STP.tentative_first_fit, Int[])

# Empty solutions for LB cost computation
tpo_empty = TPO.Solution(tpo_instance)
stp_empty = STP.Solution(stp_instance)

# Run LB on a fresh solution so we can compare resulting paths.
tpo_sol = TPO.lower_bound(tpo_instance)
stp_sol_run = STP.Solution(stp_instance)
STP.lower_bound!(stp_sol_run, stp_instance)

# Match by OD
function od_match()
    tpo_keys = Dict{Tuple{String,String},Int}()
    for (i, b) in enumerate(tpo_instance.bundles)
        tpo_keys[(b.origin_id, b.destination_id)] = i
    end
    stp_keys = Dict{Tuple{String,String},Int}()
    for (i, b) in enumerate(stp_instance.bundles)
        stp_keys[(b.supplier.account, b.customer.account)] = i
    end
    return Dict(
        k => (tpo_keys[k], stp_keys[k]) for k in keys(tpo_keys) if haskey(stp_keys, k)
    )
end
matches = od_match()

# Helpers
function tpo_path_spatial(path::Vector{Int})
    g = tpo_instance.travel_time_graph.graph
    return [label_for(g, code)[1] for code in path]
end
function stp_path_spatial(path::Vector{Int})
    ttg = stp_instance.travelTimeGraph
    return [ttg.networkNodes[code].account for code in path]
end
function collapse(ids::Vector{String})
    isempty(ids) && return ids
    out = String[ids[1]]
    for i in 2:length(ids)
        ids[i] == out[end] || push!(out, ids[i])
    end
    return out
end

# Find a diverging bundle (TPO len 2 spatial, STP len 3 spatial after collapse)
function find_diverging()
    for (od, (ti, si)) in matches
        tp = collapse(tpo_path_spatial(tpo_sol.bundle_paths[ti]))
        sp = collapse(stp_path_spatial(stp_sol_run.bundlePaths[si]))
        if length(tp) == 2 && length(sp) == 3
            @info "Diverging bundle" od ti si tpo_path = tp stp_path = sp
            return (od, ti, si)
        end
    end
    return nothing
end
_found = find_diverging()
diverging_od = _found === nothing ? nothing : _found[1]
diverging = _found === nothing ? (nothing, nothing) : (_found[2], _found[3])

if diverging_od === nothing
    @warn "No diverging bundle found with len(2,3) and matching endpoints; falling back to scanning"
    for (od, (ti, si)) in matches
        tp = collapse(tpo_path_spatial(tpo_sol.bundle_paths[ti]))
        sp = collapse(stp_path_spatial(stp_sol_run.bundlePaths[si]))
        if tp != sp
            @info "Generic divergence" od ti si tp sp
        end
    end
    error("No suitable bundle found for diagnostic")
end

ti, si = diverging
tpo_bundle = tpo_instance.bundles[ti]
stp_bundle = stp_instance.bundles[si]

# Translate spatial path into TTG codes for TPO and STP
tpo_spatial = collapse(tpo_path_spatial(tpo_sol.bundle_paths[ti]))
stp_spatial = collapse(stp_path_spatial(stp_sol_run.bundlePaths[si]))
@assert length(tpo_spatial) == 2 "TPO path is not direct"
@assert length(stp_spatial) == 3 "STP path is not 3-node"

origin_id, dest_id = tpo_spatial[1], tpo_spatial[2]
hub_id = stp_spatial[2]

# TPO TTG codes — use the actual picked path endpoints
ttg_tpo = tpo_instance.travel_time_graph
tpo_picked = tpo_sol.bundle_paths[ti]
tpo_origin_code = tpo_picked[1]
tpo_dest_code = tpo_picked[end]
# Find the hub TTG code on the shortest STP path mapped back to TPO.
# Strategy: scan TPO bundle arcs out of origin and look for a multi-hop start whose downstream lands at hub
function find_hub_codes_tpo()
    # The TTG hub code must appear as outneighbor of origin and as inneighbor of dest.
    # In TPO, bundle_arcs are (u,v) pairs valid for this bundle.
    candidates_u_to_hub = Int[]
    candidates_hub_to_v = Int[]
    for (u, v) in ttg_tpo.bundle_arcs[ti]
        u_id = label_for(ttg_tpo.graph, u)[1]
        v_id = label_for(ttg_tpo.graph, v)[1]
        if u_id == origin_id && v_id == hub_id
            push!(candidates_u_to_hub, v)
        end
        if u_id == hub_id && v_id == dest_id
            push!(candidates_hub_to_v, u)
        end
    end
    return candidates_u_to_hub, candidates_hub_to_v
end
hubs_after, hubs_before = find_hub_codes_tpo()
@info "TPO hub TTG candidate codes" hubs_after hubs_before
# Pick a pair where the v of leg1 equals the u of leg2
function pick_hub_code()
    for h in hubs_after
        if h in hubs_before
            return h
        end
    end
    return nothing
end
chosen_hub_code = pick_hub_code()
chosen_hub_code === nothing &&
    error("Could not match hub TTG code in TPO for hub_id=$hub_id")

# STP TTG codes
ttg_stp = stp_instance.travelTimeGraph
tsg_stp = stp_instance.timeSpaceGraph
stp_path = stp_sol_run.bundlePaths[si]
# After collapse, stp_path may include a shortcut self-loop at the supplier (account repeated).
# Find the indices in stp_path corresponding to origin, hub, dest (use last occurrence pattern).
stp_codes = stp_sol_run.bundlePaths[si]
# Filter out any consecutive duplicates by spatial id while preserving codes
function dedupe_codes(codes)
    isempty(codes) && return codes
    out = [codes[1]]
    for i in 2:length(codes)
        if ttg_stp.networkNodes[codes[i]].account !=
            ttg_stp.networkNodes[codes[i - 1]].account
            push!(out, codes[i])
        end
    end
    return out
end
stp_clean = dedupe_codes(stp_codes)
@assert length(stp_clean) == 3 "Expected 3-node STP path, got $stp_clean"
stp_origin_code, stp_hub_code, stp_dest_code = stp_clean[1], stp_clean[2], stp_clean[3]

println("\nTPO chosen path raw TTG codes: ", tpo_sol.bundle_paths[ti])
println(
    "TPO chosen path raw spatial+stepToDel: ",
    [label_for(ttg_tpo.graph, c) for c in tpo_sol.bundle_paths[ti]],
)
println("STP chosen path raw TTG codes: ", stp_sol_run.bundlePaths[si])
println(
    "STP chosen path raw spatial+stepToDel: ",
    [
        (ttg_stp.networkNodes[c].account, ttg_stp.stepToDel[c]) for
        c in stp_sol_run.bundlePaths[si]
    ],
)
println("TPO bundle origin/dest TTG codes: ", tpo_origin_code, " / ", tpo_dest_code)
println("\n=========================")
println("Diverging bundle: OD = ", diverging_od)
println("  TPO bundle idx = $ti, STP bundle idx = $si")
println("  TPO path: $tpo_spatial")
println("  STP path: $stp_spatial (collapsed)")
println("  origin=$origin_id  hub=$hub_id  dest=$dest_id")
println("=========================\n")

# TPO per-arc LB cost via the high-level function used by lower_bound!
tpo_direct = TPO.compute_ttg_edge_lower_bound_cost(
    tpo_empty, tpo_instance, tpo_bundle, tpo_origin_code, tpo_dest_code
)
tpo_leg1 = TPO.compute_ttg_edge_lower_bound_cost(
    tpo_empty, tpo_instance, tpo_bundle, tpo_origin_code, chosen_hub_code
)
tpo_leg2 = TPO.compute_ttg_edge_lower_bound_cost(
    tpo_empty, tpo_instance, tpo_bundle, chosen_hub_code, tpo_dest_code
)

# STP per-arc LB cost (full = volume_stock_cost + transport)
function stp_arc_decomp(src, dst)
    full = 0.0
    vsc = 0.0
    trn = 0.0
    for order in stp_bundle.orders
        timedSrc, timedDst = STP.time_space_projector(ttg_stp, tsg_stp, src, dst, order)
        vc = STP.volume_stock_cost(ttg_stp, src, dst, order)
        tu = STP.lb_transport_units(
            stp_empty, tsg_stp, timedSrc, timedDst, order; use_bins=false, giant=false
        )
        tc = STP.transport_cost(tsg_stp, timedSrc, timedDst; current_cost=false)
        vsc += vc
        trn += tu * tc
    end
    full = vsc + trn
    return (; full, volume_stock_cost=vsc, transport=trn)
end
stp_direct = stp_arc_decomp(stp_origin_code, stp_dest_code)
stp_leg1 = stp_arc_decomp(stp_origin_code, stp_hub_code)
stp_leg2 = stp_arc_decomp(stp_hub_code, stp_dest_code)

# Also dump cumulative
function row(label, tpo_v, stp_v)
    @printf(
        "  %-12s | TPO=%12.4f | STP_full=%12.4f | STP_vsc=%12.4f | STP_trn=%12.4f | TPO/STP_trn=%6.3f\n",
        label,
        tpo_v,
        stp_v.full,
        stp_v.volume_stock_cost,
        stp_v.transport,
        tpo_v == 0 ? NaN : tpo_v / max(stp_v.transport, 1e-9)
    )
end
println("Per-arc LB cost decomposition:")
row("DIRECT", tpo_direct, stp_direct)
row("LEG1 ->hub", tpo_leg1, stp_leg1)
row("LEG2 hub->", tpo_leg2, stp_leg2)
println()
@printf("  TPO multi-hop sum (legs1+2) = %.4f\n", tpo_leg1 + tpo_leg2)
@printf("  STP multi-hop sum FULL      = %.4f\n", stp_leg1.full + stp_leg2.full)
@printf("  STP multi-hop sum TRANSPORT = %.4f\n", stp_leg1.transport + stp_leg2.transport)
@printf(
    "  STP multi-hop sum VSC       = %.4f\n",
    stp_leg1.volume_stock_cost + stp_leg2.volume_stock_cost
)
println()
@printf(
    "  TPO direct - TPO multi-hop  = %.4f  (TPO picks direct iff this <= 0)\n",
    tpo_direct - (tpo_leg1 + tpo_leg2)
)
@printf(
    "  STP direct.full - STP MH.full = %.4f  (STP picks direct iff this <= 0)\n",
    stp_direct.full - (stp_leg1.full + stp_leg2.full)
)
@printf(
    "  STP direct.transport-only - STP MH.transport-only = %.4f\n",
    stp_direct.transport - (stp_leg1.transport + stp_leg2.transport)
)
println()

# Sanity: dump volumes and arc capacities to confirm get_lb_transport_units behavior on direct
println("Bundle volume / arc details:")
for o in stp_bundle.orders
    arcD = stp_instance.networkGraph.graph[
        hash(origin_id, hash(:supplier)), hash(dest_id, hash(:plant))
    ]
    @printf(
        "  STP order vol=%d  direct cap=%d  type=%s  is_linear=%s  ceil=%.4f  frac=%.4f  unitCost=%.2f\n",
        o.volume,
        arcD.capacity,
        arcD.type,
        arcD.isLinear,
        ceil(o.volume / arcD.capacity),
        o.volume / arcD.capacity,
        arcD.unitCost,
    )
end
