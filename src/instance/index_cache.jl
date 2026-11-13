"""
$TYPEDEF

Spatial codes of the forbidden constraints of a bundle, resolved from its user ids.

# Fields
$TYPEDFIELDS
"""
struct ForbiddenCodes
    "spatial codes of the forbidden nodes"
    nodes::Set{Int}
    "forbidden edge code pairs (all modes)"
    arcs::Set{Tuple{Int,Int}}
end

"""
$TYPEDEF

Precomputed integer-indexed lookup tables, derived once from the instance graphs, the user nodes and the bundles and never mutated.
They replace MetaGraphsNext label-to-code hashing with flat array indexing.
Unlike the construction-time `EndpointSplit` fields `origin_copy` and `destination_copy` (user ids to copy ids, including nodes without a hub), `hub_origin_copy` and `hub_destination_copy` are indexed by spatial code and only cover hubs.

# Fields
$TYPEDFIELDS
"""
struct IndexCache{ARC,NC}
    "travel-time node code to network (spatial) node code"
    ttg_code_to_spatial_code::Vector{Int}
    "travel-time node code to its location: the `input_index` of its network node, or `n_input_nodes + spatial code` for a network node without an input node. Loop checks compare locations, so the copies of a user node count as one location, and the key never collides"
    ttg_code_to_location::Vector{Int}
    "travel-time node code to its time budget tau"
    ttg_code_to_tau::Vector{Int}
    "(spatial code, time budget tau + 1) to travel-time node code (0 means absent)"
    spatial_code_and_tau_to_ttg_code::Matrix{Int}
    "(spatial code, time step) to time-space node code (0 means absent)"
    spatial_code_and_time_to_tsg_code::Matrix{Int}
    "time-space node code to network (spatial) node code"
    tsg_code_to_spatial_code::Vector{Int}
    "time-space node code to its absolute time step t"
    tsg_code_to_time::Vector{Int}
    "(spatial u, spatial v, transit key) to the edge arc (plain arc or sub-multi-modal arc)"
    edge_group_to_arc::Dict{Tuple{Int,Int,Int},ARC}
    "spatial code to destination node cost"
    spatial_code_to_node_cost::Vector{NC}
    "spatial code of a hub to that of its origin copy (0 if none)"
    hub_origin_copy::Vector{Int}
    "spatial code of a hub to that of its destination copy (0 if none)"
    hub_destination_copy::Vector{Int}
    "user node id to the spatial codes of its internal nodes (the node itself and its endpoint copies), nodes without an input node (`input_index == 0`) are left out"
    input_node_codes::Dict{String,Vector{Int}}
    "per bundle index, the spatial codes of its forbidden nodes and its forbidden edge code pairs, resolved once from the user ids by provenance (see [`_resolve_forbidden_codes`](@ref))"
    forbidden_codes::Vector{ForbiddenCodes}
    "length of the time horizon of the time-space graph"
    time_horizon_length::Int
    "whether transit times wrap around the time horizon"
    wrap_time::Bool
end

"""
$TYPEDSIGNATURES

Travel-time node code at spatial code `s` and time budget `τ`, or `0` if there is none (including `τ` out of range).
"""
@inline function ttg_code_at(cache::IndexCache, s::Int, τ::Int)
    codes = cache.spatial_code_and_tau_to_ttg_code
    return 1 <= τ + 1 <= size(codes, 2) ? codes[s, τ + 1] : 0
end

"""
$TYPEDSIGNATURES

Key of a transit time `d` in `IndexCache.edge_group_to_arc` (reduced modulo the horizon
length `H` when `wrap_time` is set).
"""
_transit_key(d::Int, H::Int, wrap_time::Bool) = wrap_time ? mod(d, H) : d

"""
$TYPEDSIGNATURES

Key `(spatial u, spatial v, transit key)` of the travel-time edge `u -> v` (codes).
The transit time is read from the time budgets of the two endpoints.
"""
@inline function ttg_edge_key(cache::IndexCache, u::Int, v::Int)
    d = abs(cache.ttg_code_to_tau[u] - cache.ttg_code_to_tau[v])
    return (
        cache.ttg_code_to_spatial_code[u],
        cache.ttg_code_to_spatial_code[v],
        _transit_key(d, cache.time_horizon_length, cache.wrap_time),
    )
end

"""
$TYPEDSIGNATURES

Key `(spatial u, spatial v, transit key)` of the time-space edge `u -> v` (codes).
The transit time is the time difference of the two endpoints.
"""
@inline function tsg_edge_key(cache::IndexCache, u::Int, v::Int)
    d = cache.tsg_code_to_time[v] - cache.tsg_code_to_time[u]
    return (
        cache.tsg_code_to_spatial_code[u],
        cache.tsg_code_to_spatial_code[v],
        _transit_key(d, cache.time_horizon_length, cache.wrap_time),
    )
end

"""
$TYPEDSIGNATURES

Edge arc of the travel-time edge `u -> v` (codes), or `nothing` if absent.
"""
@inline function ttg_edge_arc(cache::IndexCache, u::Int, v::Int)
    return get(cache.edge_group_to_arc, ttg_edge_key(cache, u, v), nothing)
end

"""
$TYPEDSIGNATURES

Whether the travel-time edge `u -> v` (codes) is a virtual arc of an endpoint split.
Shortcut edges (same spatial node) have no arc and are not virtual.
"""
@inline function _is_virtual_ttg_edge(cache::IndexCache, u::Int, v::Int)
    arc = ttg_edge_arc(cache, u, v)
    return !isnothing(arc) && _is_virtual(arc)
end

"""
$TYPEDSIGNATURES

Edge arc of the time-space edge `u -> v` (codes), or `nothing` if absent.
"""
@inline function tsg_edge_arc(cache::IndexCache, u::Int, v::Int)
    return get(cache.edge_group_to_arc, tsg_edge_key(cache, u, v), nothing)
end

"""
$TYPEDSIGNATURES

Build the [`IndexCache`](@ref) from the instance graphs, the user `input_nodes` and the `bundles`.
The forbidden constraints of `bundles[i]` are resolved once into `forbidden_codes[i]`, so the cache must be rebuilt when the bundles change.
Runs in `build_instance` (before the bundles are validated) and in `extract_filtered_instance`.
"""
function build_index_cache(
    network_graph::NetworkGraph,
    travel_time_graph::TravelTimeGraph,
    time_space_graph::TimeSpaceGraph,
    input_nodes::AbstractVector{<:Node},
    bundles::AbstractVector{<:Bundle},
)
    ng = network_graph.graph
    ttg = travel_time_graph.graph
    tsg = time_space_graph.graph
    time_horizon_length = time_space_graph.time_horizon_length
    n_net = Graphs.nv(ng)

    n_ttg = Graphs.nv(ttg)
    ttg_code_to_spatial_code = Vector{Int}(undef, n_ttg)
    ttg_code_to_tau = Vector{Int}(undef, n_ttg)
    for code in 1:n_ttg
        loc, τ = MetaGraphsNext.label_for(ttg, code)
        ttg_code_to_spatial_code[code] = MetaGraphsNext.code_for(ng, loc)
        ttg_code_to_tau[code] = τ
    end
    n_input = length(input_nodes)
    spatial_code_to_location = map(1:n_net) do c
        i = ng[MetaGraphsNext.label_for(ng, c)].input_index
        return iszero(i) ? n_input + c : i
    end
    ttg_code_to_location = spatial_code_to_location[ttg_code_to_spatial_code]
    spatial_code_and_tau_to_ttg_code = zeros(
        Int, n_net, maximum(ttg_code_to_tau; init=0) + 1
    )  # 0 encodes "no TTG node at this (spatial, τ) pair"
    for code in 1:n_ttg
        spatial_code_and_tau_to_ttg_code[
            ttg_code_to_spatial_code[code], ttg_code_to_tau[code] + 1
        ] = code
    end

    n_tsg = Graphs.nv(tsg)
    tsg_code_to_spatial_code = Vector{Int}(undef, n_tsg)
    tsg_code_to_time = Vector{Int}(undef, n_tsg)
    spatial_code_and_time_to_tsg_code = zeros(Int, n_net, time_horizon_length)  # 0 encodes "no TSG node at this (spatial, t) pair"
    for code in 1:n_tsg
        nid, t = MetaGraphsNext.label_for(tsg, code)
        s = MetaGraphsNext.code_for(ng, nid)
        tsg_code_to_spatial_code[code] = s
        tsg_code_to_time[code] = t
        spatial_code_and_time_to_tsg_code[s, t] = code
    end

    wrap_time = time_space_graph.wrap_time
    entries = [
        (
            MetaGraphsNext.code_for(ng, u),
            MetaGraphsNext.code_for(ng, v),
            _transit_key(d, time_horizon_length, wrap_time),
        ) => edge_arc for (u, v) in MetaGraphsNext.edge_labels(ng) for
        (d, edge_arc) in _mode_groups(ng[u, v])
    ]
    ARC = Union{(typeof(arc) for (_, arc) in entries)...}
    edge_group_to_arc = Dict{Tuple{Int,Int,Int},ARC}(entries)

    # Endpoint copies of the hubs, read off the virtual arcs `v_o -> v` and `v -> v_d`.
    hub_origin_copy = zeros(Int, n_net)
    hub_destination_copy = zeros(Int, n_net)
    for (u, v) in MetaGraphsNext.edge_labels(ng)
        _is_virtual(ng[u, v]) || continue
        cu, cv = MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)
        if ng[u].node_type == :origin
            hub_origin_copy[cv] = cu
        else
            hub_destination_copy[cu] = cv
        end
    end

    # Union of the concrete `node_cost` types actually present, narrower than `AbstractNodeCostFunction` for mixed instances, regardless of how `ng` was built.
    NC = if n_net == 0
        AbstractNodeCostFunction
    else
        Union{(typeof(ng[l].node_cost) for l in MetaGraphsNext.labels(ng))...}
    end
    spatial_code_to_node_cost = NC[
        ng[MetaGraphsNext.label_for(ng, c)].node_cost for c in 1:n_net
    ]

    input_node_codes = Dict{String,Vector{Int}}()
    for code in 1:n_net
        node = ng[MetaGraphsNext.label_for(ng, code)]
        iszero(node.input_index) && continue
        push!(get!(input_node_codes, input_nodes[node.input_index].id, Int[]), code)
    end

    bundle_forbidden = ForbiddenCodes[
        _resolve_forbidden_codes(input_node_codes, ng, bundle) for bundle in bundles
    ]

    return IndexCache(
        ttg_code_to_spatial_code,
        ttg_code_to_location,
        ttg_code_to_tau,
        spatial_code_and_tau_to_ttg_code,
        spatial_code_and_time_to_tsg_code,
        tsg_code_to_spatial_code,
        tsg_code_to_time,
        edge_group_to_arc,
        spatial_code_to_node_cost,
        hub_origin_copy,
        hub_destination_copy,
        input_node_codes,
        bundle_forbidden,
        time_horizon_length,
        wrap_time,
    )
end

"""
$TYPEDSIGNATURES

The [`ForbiddenCodes`](@ref) of `bundle`, resolved by provenance.
`input_node_codes` is `IndexCache.input_node_codes` and `ng` the network graph.
A forbidden user node id gives the codes of all its internal nodes (the node and its endpoint copies).
A forbidden arc `(u, v)` gives every pair `(cu, cv)` of internal nodes of `u` and `v` joined by an arc of
`ng`, so it forbids the arc in every mode, and a skipped input arc gives no pair.
A loop `(u, u)` gives no pair.
Ids absent from `input_node_codes` are skipped, they are nodes dropped by an instance extraction
and can no longer be traversed.
`build_index_cache` calls it once per bundle, use [`forbidden_codes`](@ref) to read the result.
"""
function _resolve_forbidden_codes(
    input_node_codes::Dict{String,Vector{Int}}, ng::MetaGraph, bundle::Bundle
)
    fn = Set{Int}()
    for id in bundle.forbidden_nodes
        union!(fn, get(input_node_codes, id, Int[]))
    end
    fa = Set{Tuple{Int,Int}}()
    for (u, v) in bundle.forbidden_arcs
        u == v && continue
        codes_u = get(input_node_codes, u, Int[])
        codes_v = get(input_node_codes, v, Int[])
        for cu in codes_u, cv in codes_v
            Graphs.has_edge(ng, cu, cv) && push!(fa, (cu, cv))
        end
    end
    return ForbiddenCodes(fn, fa)
end

"""
$TYPEDSIGNATURES

Stored [`ForbiddenCodes`](@ref) of the bundle `bundle_idx` of the instance the cache was built for.
"""
forbidden_codes(cache::IndexCache, bundle_idx::Int) = cache.forbidden_codes[bundle_idx]
