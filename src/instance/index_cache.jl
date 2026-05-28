"""
$TYPEDEF

Precomputed integer-indexed lookup tables for the construction hot path, derived
once from the instance graphs and never mutated. They replace MetaGraphsNext
label-to-code hashing (the dominant construction cost) with flat array indexing.

The spatial code is the MetaGraphsNext code of a node in `network_graph.graph`
(a dense integer in `1:nv`). Because `IndexCache` is a type parameter of
`Instance` (the `IC` slot), all fields, including `arc_of` and `node_cost_of`,
are accessed type-stably. The dispatch quality for `arc_of` and `node_cost_of`
is the same as a direct MetaGraph lookup: union-splitting over the concrete
arc and node-cost types that were present at construction time.

# Fields
$TYPEDFIELDS
"""
struct IndexCache{ARC,NC}
    "travel-time node code to network (spatial) node code"
    ttg_spatial::Vector{Int}
    "travel-time node code to its time budget tau"
    ttg_tau::Vector{Int}
    "(spatial code, time step) to time-space node code (0 means absent)"
    tsg_code_of::Matrix{Int}
    "time-space node code to network (spatial) node code"
    tsg_spatial::Vector{Int}
    "(spatial u, spatial v) to arc metadata"
    arc_of::Dict{Tuple{Int,Int},ARC}
    "spatial code to destination node cost"
    node_cost_of::Vector{NC}
end

"""
$TYPEDSIGNATURES

Build the [`IndexCache`](@ref) from the instance graphs. Runs once at the end of
`build_instance`. Cost is `O(N_ttg + N_tsg + N_arcs)`, negligible against a
sweep.
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
    ttg_spatial = Vector{Int}(undef, n_ttg)
    ttg_tau = Vector{Int}(undef, n_ttg)
    for code in 1:n_ttg
        loc, τ = MetaGraphsNext.label_for(ttg, code)
        ttg_spatial[code] = MetaGraphsNext.code_for(ng, loc)
        ttg_tau[code] = τ
    end

    n_tsg = Graphs.nv(tsg)
    tsg_spatial = Vector{Int}(undef, n_tsg)
    tsg_code_of = zeros(Int, n_net, time_horizon_length)  # 0 encodes "no TSG node at this (spatial, t) pair"
    for code in 1:n_tsg
        nid, t = MetaGraphsNext.label_for(tsg, code)
        s = MetaGraphsNext.code_for(ng, nid)
        tsg_spatial[code] = s
        tsg_code_of[s, t] = code
    end

    arc_of = Dict(
        (MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)) => ng[u, v] for
        (u, v) in MetaGraphsNext.edge_labels(ng)
    )

    # NC is inferred from the node cost types: homogeneous instances stay concrete,
    # mixed node-cost-type instances widen NC to AbstractNodeCostFunction.
    node_cost_of = [ng[MetaGraphsNext.label_for(ng, c)].node_cost for c in 1:n_net]

    return IndexCache(ttg_spatial, ttg_tau, tsg_code_of, tsg_spatial, arc_of, node_cost_of)
end
