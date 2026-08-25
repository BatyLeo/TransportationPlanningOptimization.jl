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
    "(spatial code, time step) to time-space node code (0 means absent)"
    spatial_code_and_time_to_tsg_code::Matrix{Int}
    "time-space node code to network (spatial) node code"
    tsg_code_to_spatial_code::Vector{Int}
    "(spatial u, spatial v) to arc metadata"
    spatial_pair_to_arc::Dict{Tuple{Int,Int},ARC}
    "spatial code to destination node cost"
    spatial_code_to_node_cost::Vector{NC}
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

    n_tsg = Graphs.nv(tsg)
    tsg_code_to_spatial_code = Vector{Int}(undef, n_tsg)
    spatial_code_and_time_to_tsg_code = zeros(Int, n_net, time_horizon_length)  # 0 encodes "no TSG node at this (spatial, t) pair"
    for code in 1:n_tsg
        nid, t = MetaGraphsNext.label_for(tsg, code)
        s = MetaGraphsNext.code_for(ng, nid)
        tsg_code_to_spatial_code[code] = s
        spatial_code_and_time_to_tsg_code[s, t] = code
    end

    spatial_pair_to_arc = Dict(
        (MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)) => ng[u, v] for
        (u, v) in MetaGraphsNext.edge_labels(ng)
    )

    spatial_code_to_node_cost = [
        ng[MetaGraphsNext.label_for(ng, c)].node_cost for c in 1:n_net
    ]

    return IndexCache(
        ttg_code_to_spatial_code,
        ttg_code_to_tau,
        spatial_code_and_time_to_tsg_code,
        tsg_code_to_spatial_code,
        spatial_pair_to_arc,
        spatial_code_to_node_cost,
    )
end
