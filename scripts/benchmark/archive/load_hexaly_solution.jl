using Pkg
Pkg.activate(joinpath(@__DIR__, "..", ".."))

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using Dates
using CSV, DataFrames
using MetaGraphsNext

include(joinpath(@__DIR__, "Outbound.jl"))
using .Outbound

const DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "outbound", "dataMVP")

println("=== Build instance (model_costs=true, group_by=model) ===")
(; nodes, arcs, commodities) = Outbound.parse_dataMVP_instance(DATA_DIR; model_costs=true)
instance = Instance(
    nodes,
    arcs,
    commodities,
    Day(600);
    wrap_time=false,
    allow_multimodal=true,
    group_by=c -> c.info.model,
)
println("bundles=$(bundle_count(instance))")

# ---- Parse result_NDO.csv into per-route ordered paths ----
df = DataFrame(CSV.File(joinpath(DATA_DIR, "output", "result_NDO.csv"); decimal=','))
println("\n=== Hexaly routing ===")
println("legs=$(nrow(df))  unique routes=$(length(unique(df.IDRoute)))")

# Group by IDRoute; each route is a sequence of legs in LegOrder
routes = Dict{
    Int,NamedTuple{(:nodes, :model, :volume),Tuple{Vector{String},String,Float64}}
}()
for sub in groupby(df, :IDRoute)
    sorted = sort(sub, :LegOrder)
    # path = first origin then each leg's destination
    path_nodes = String[sorted[1, :OrigineLeg]]
    for r in eachrow(sorted)
        push!(path_nodes, r.DestinationLeg)
    end
    # model: extract from "mod_BJA&&CLSI NOVO" -> "BJA"
    mod_str = sorted[1, :Modele]
    m = replace(mod_str, "mod_" => "")
    m = split(m, "&&")[1]
    rid = sorted[1, :IDRoute]
    routes[rid] = (nodes=path_nodes, model=String(m), volume=Float64(sorted[1, :Volume]))
end

# Dominant route per (origin, dest, model): the one with max volume
od_dominant = Dict{Tuple{String,String,String},Int}()
od_supply = Dict{Tuple{String,String,String},Float64}()
od_split = Dict{Tuple{String,String,String},Int}()
for (rid, r) in routes
    key = (r.nodes[1], r.nodes[end], r.model)
    od_supply[key] = get(od_supply, key, 0.0) + r.volume
    od_split[key] = get(od_split, key, 0) + 1
    if !haskey(od_dominant, key) || routes[od_dominant[key]].volume < r.volume
        od_dominant[key] = rid
    end
end
println("OD-model keys in Hexaly: $(length(od_supply))")
println("  split across 2 routes: $(count(v -> v >= 2, values(od_split)))")
println("  single route          : $(count(v -> v == 1, values(od_split)))")

# ---- Build TPO Solution by assigning each bundle the dominant Hexaly path ----
ttg = instance.travel_time_graph
graph = ttg.graph

# Helper: given string path, build the TTG int-code path.
# Outbound uses departure dates with travel_time=0 everywhere, so τ stays at 0
# throughout. Try a few τ candidates and pick the one that works.
function to_ttg_path(g, str_path::Vector{String})
    for τ_try in (0, 1)  # try both in case of off-by-one
        codes = Int[]
        ok = true
        for nid in str_path
            label = (nid, τ_try)
            if haskey(g.vertex_properties, label)
                push!(codes, code_for(g, label))
            else
                ok = false
                break
            end
        end
        ok && return codes
    end
    return nothing
end

sol = Solution(instance)
matched = Ref(0)
unmatched_bundles = String[]
path_failed = String[]

for (bidx, bundle) in enumerate(instance.bundles)
    # Bundle has no `info` field; the model lives on each commodity (set by group_by).
    bmodel = string(bundle.orders[1].commodities[1].info.model)
    key = (bundle.origin_id, bundle.destination_id, bmodel)
    if !haskey(od_dominant, key)
        push!(unmatched_bundles, "$key")
        continue
    end
    rid = od_dominant[key]
    str_path = routes[rid].nodes
    int_path = to_ttg_path(graph, str_path)
    if int_path === nothing
        push!(path_failed, "$(key) -> $(str_path) (no TTG codes)")
        continue
    end
    add_bundle_path!(sol, instance, bidx, int_path)
    matched[] += 1
end

println("\n=== Loaded ===")
println("bundles matched : $(matched[]) / $(bundle_count(instance))")
println("unmatched (no Hexaly route): $(length(unmatched_bundles))")
length(unmatched_bundles) > 0 && println("  examples: ", first(unmatched_bundles, 3))
println("path lookup failed: $(length(path_failed))")
length(path_failed) > 0 && println("  examples: ", first(path_failed, 3))

println("\n=== is_feasible(sol, instance; verbose=true) ===")
ok = is_feasible(sol, instance; verbose=true)
println("\n=> is_feasible: $ok")

c = cost(sol)
println("\ncost(sol)        = $c")
println("Hexaly accounting = 19569213.0")
println("greedy benchmark = 20119065.0")
