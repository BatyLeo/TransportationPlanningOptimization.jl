# --- Pre-allocated Dijkstra workspace (avoids per-call array allocation) ---

struct DijkstraWorkspace
    dists::Vector{Float64}
    parents::Vector{Int}
end

function DijkstraWorkspace(n::Int)
    return DijkstraWorkspace(Vector{Float64}(undef, n), Vector{Int}(undef, n))
end

function _reset_workspace!(ws::DijkstraWorkspace, origin::Int)
    fill!(ws.dists, Inf)
    fill!(ws.parents, 0)
    ws.dists[origin] = 0.0
    return ws
end

"""
$TYPEDSIGNATURES

Dijkstra shortest path on the `TravelTimeGraph`, skipping edges whose cost
is `Inf`. Returns `(parents, dists)` where `parents[v]` is the predecessor
of `v` on the shortest path from `src` and `dists[v]` is the distance.

The standard `Graphs.dijkstra_shortest_paths` pushes every neighbor into the
priority queue even when the edge cost is `Inf`, which is wasteful when only
a small fraction of edges carry finite costs.
This version skips `Inf` edges entirely, reducing the number of priority
queue operations from O(V) to O(bundle_arcs).

When `dst > 0`, the search terminates as soon as `dst` is settled (popped
from the heap with its final distance). The returned `parents` and `dists`
are only populated for nodes settled before (and including) `dst`. This is
sufficient for `trace_path(parents, src, dst)` and avoids exploring arcs
beyond the destination.
"""
function bundle_dijkstra(
    graph::Graphs.AbstractGraph,
    src::Int,
    cost_matrix::SparseMatrixCSC{Float64,Int};
    dst::Int=0,
    workspace=nothing,
)
    if isnothing(workspace)
        n = Graphs.nv(graph)
        dists = fill(Inf, n)
        parents = zeros(Int, n)
        dists[src] = 0.0
    else
        _reset_workspace!(workspace, src)
        dists = workspace.dists
        parents = workspace.parents
    end

    heap = DataStructures.BinaryMinHeap{Tuple{Float64,Int}}()
    push!(heap, (0.0, src))

    while !isempty(heap)
        d_u, u = pop!(heap)

        # Skip if this is a stale entry (we already found a shorter path to `u`)
        if d_u > dists[u]
            continue
        end

        # If we have a destination and we just popped it from the heap, we can stop
        if dst > 0 && u == dst
            break
        end

        for v in Graphs.outneighbors(graph, u)
            w = cost_matrix[u, v]
            if isinf(w) # skip edges with infinite cost
                continue
            end
            alt = d_u + w
            if alt < dists[v]
                dists[v] = alt
                parents[v] = u
                push!(heap, (alt, v))
            end
        end
    end

    return parents, dists
end

"""
$TYPEDSIGNATURES

Reconstruct the path from `src` to `dst` using the `parents` array returned
by [`bundle_dijkstra`](@ref). Returns an empty vector if `dst` is unreachable.
"""
function trace_path(parents::Vector{Int}, src::Int, dst::Int)
    parents[dst] == 0 && dst != src && return Int[]
    path = Int[dst]
    v = dst
    while v != src
        v = parents[v]
        push!(path, v)
    end
    reverse!(path)
    return path
end

"""
$TYPEDSIGNATURES

Whether `path` (TTG codes) never revisits a physical node after leaving it.
`spatial` maps a TTG code to its physical node code. Consecutive repeats of the
same physical node count as waiting and are allowed.
"""
function is_elementary_path(path::AbstractVector{Int}, spatial::AbstractVector{Int})
    for j in 3:length(path)
        s = spatial[path[j]]
        s == spatial[path[j - 1]] && continue
        for i in 1:(j - 2)
            spatial[path[i]] == s && return false
        end
    end
    return true
end

"""
$TYPEDSIGNATURES

Cheapest elementary path from `src` to `dst` (TTG codes), or `Int[]` if none exists.
Label-setting search where each label carries the set of physical nodes it has
visited, so a physical node is never entered twice (staying on the current one is
waiting and is allowed). `visited` lists physical nodes that the path must also
avoid. The node of `src` is always allowed, and if the node of `dst` is in `visited`
then no path is returned. Arcs with `Inf` cost are skipped, and costs must be nonnegative.
"""
function elementary_shortest_path(
    graph::Graphs.AbstractGraph,
    cost_matrix::SparseMatrixCSC{Float64,Int},
    spatial::AbstractVector{Int},
    src::Int,
    dst::Int;
    visited::BitSet=BitSet(),
)
    # Label k: vertex[k], parent[k] (label index) and seen[k] (physical nodes).
    vertex = [src]
    parent = [0]
    seen = [push!(copy(visited), spatial[src])]
    settled = Dict{Int,Vector{Int}}()
    heap = DataStructures.BinaryMinHeap{Tuple{Float64,Int}}()
    push!(heap, (0.0, 1))

    while !isempty(heap)
        d, k = pop!(heap)
        u = vertex[k]
        # Dominated by a settled label at the same vertex whose visited nodes are a subset
        labels = get!(Vector{Int}, settled, u)
        any(l -> issubset(seen[l], seen[k]), labels) && continue
        push!(labels, k)

        if u == dst
            path = Int[]
            while k != 0
                push!(path, vertex[k])
                k = parent[k]
            end
            return reverse!(path)
        end

        for v in Graphs.outneighbors(graph, u)
            w = cost_matrix[u, v]
            isinf(w) && continue
            sv = spatial[v]
            if sv != spatial[u] && sv in seen[k]
                continue
            end
            push!(vertex, v)
            push!(parent, k)
            push!(seen, push!(copy(seen[k]), sv))
            push!(heap, (d + w, length(vertex)))
        end
    end
    return Int[]
end

"""
$TYPEDSIGNATURES

Cheapest elementary path from `src` to `dst` for the bundle whose costs are in
`instance.travel_time_graph.cost_matrix`. Runs [`bundle_dijkstra`](@ref) first and
returns its path when it is empty or elementary. Only when that path loops on a
physical node does it run [`elementary_shortest_path`](@ref).
"""
function bundle_shortest_path(instance::Instance, src::Int, dst::Int; workspace=nothing)
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    parents, _ = bundle_dijkstra(ttg.graph, src, ttg.cost_matrix; dst, workspace)
    path = trace_path(parents, src, dst)
    is_elementary_path(path, spatial) && return path
    return elementary_shortest_path(ttg.graph, ttg.cost_matrix, spatial, src, dst)
end
