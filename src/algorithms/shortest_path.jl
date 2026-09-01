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
