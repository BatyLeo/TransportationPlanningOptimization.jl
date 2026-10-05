"""
$TYPEDEF

Precomputed integer-indexed lookup tables, derived once from the instance graphs and never mutated.
They replace MetaGraphsNext label-to-code hashing with flat array indexing.

# Fields
$TYPEDFIELDS
"""
struct IndexCache{ARC,NC}
    "travel-time node code to network (spatial) node code"
    ttg_code_to_spatial_code::Vector{Int}
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

Edge arc of the time-space edge `u -> v` (codes), or `nothing` if absent.
"""
@inline function tsg_edge_arc(cache::IndexCache, u::Int, v::Int)
    return get(cache.edge_group_to_arc, tsg_edge_key(cache, u, v), nothing)
end

"""
$TYPEDSIGNATURES

Build the [`IndexCache`](@ref) from the instance graphs.
Runs once at the end of `build_instance`.
"""
function build_index_cache(
    network_graph::NetworkGraph,
    travel_time_graph::TravelTimeGraph,
    time_space_graph::TimeSpaceGraph,
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

    # Union of the concrete `node_cost` types actually present, narrower than `AbstractNodeCostFunction` for mixed instances, regardless of how `ng` was built.
    NC = if n_net == 0
        AbstractNodeCostFunction
    else
        Union{(typeof(ng[l].node_cost) for l in MetaGraphsNext.labels(ng))...}
    end
    spatial_code_to_node_cost = NC[
        ng[MetaGraphsNext.label_for(ng, c)].node_cost for c in 1:n_net
    ]

    return IndexCache(
        ttg_code_to_spatial_code,
        ttg_code_to_tau,
        spatial_code_and_tau_to_ttg_code,
        spatial_code_and_time_to_tsg_code,
        tsg_code_to_spatial_code,
        tsg_code_to_time,
        edge_group_to_arc,
        spatial_code_to_node_cost,
        time_horizon_length,
        wrap_time,
    )
end
