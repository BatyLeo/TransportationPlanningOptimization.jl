"""
$TYPEDSIGNATURES

Dijkstra shortest path on the `TravelTimeGraph`, skipping edges whose cost
is `Inf`. Returns `(parents, dists)` where `parents[v]` is the predecessor
of `v` on the shortest path from `src` and `dists[v]` is the distance.

The standard `Graphs.dijkstra_shortest_paths` pushes every neighbor into the
priority queue even when the edge cost is `Inf`, which is wasteful when only
a small fraction of edges (the current bundle's arcs) carry finite costs.
This version skips `Inf` edges entirely, reducing the number of priority
queue operations from O(V) to O(bundle_arcs).
"""
function bundle_dijkstra(
    graph::Graphs.AbstractGraph, src::Int, cost_matrix::SparseMatrixCSC{Float64,Int}
)
    n = Graphs.nv(graph)
    dists = fill(Inf, n)
    parents = zeros(Int, n)
    dists[src] = 0.0

    # Lazy min-heap: may contain stale entries (a vertex pushed before a
    # shorter path was found). Stale pops are detected by the dists check.
    heap = DataStructures.BinaryMinHeap{Tuple{Float64,Int}}()
    push!(heap, (0.0, src))

    while !isempty(heap)
        d_u, u = pop!(heap)
        d_u > dists[u] && continue

        for v in Graphs.outneighbors(graph, u)
            w = cost_matrix[u, v]
            w == Inf && continue
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
