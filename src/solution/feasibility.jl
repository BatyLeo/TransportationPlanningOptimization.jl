"""
$TYPEDSIGNATURES

Check if a solution is feasible for a given instance.
Feasibility requires:
1. Every bundle in the instance must have a corresponding path in the solution.
2. Every path must exist (each arc exists in the graph).
3. Every path must start at the bundle's designated entry node (`origin_codes`).
4. Every path must end at the bundle's designated exit node (`destination_codes`).
"""
function is_feasible(sol::Solution, instance::Instance; verbose::Bool=false, tol=1e-8)
    (; travel_time_graph, time_space_graph) = instance
    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        if isempty(path)
            verbose && @warn "Bundle $(bundle_idx) has an empty path."
            return false
        end

        bundle = instance.bundles[bundle_idx]

        # Check connectivity and forbidden constraints
        for i in 1:(length(path) - 1)
            u, v = path[i], path[i + 1]
            if !Graphs.has_edge(travel_time_graph.graph, u, v)
                verbose &&
                    @warn "Arc ($(u), $(v)) in bundle $(bundle_idx) path does not exist."
                return false
            end

            # Check forbidden nodes (intermediate nodes only, origin/destination already validated)
            u_label = MetaGraphsNext.label_for(travel_time_graph.graph, u)
            v_label = MetaGraphsNext.label_for(travel_time_graph.graph, v)
            u_node_id = u_label[1]
            v_node_id = v_label[1]

            # Check if intermediate nodes are forbidden (skip origin and destination)
            if i > 1 && u_node_id in bundle.forbidden_nodes
                verbose &&
                    @warn "Bundle $(bundle_idx) path uses forbidden node $(u_node_id) at position $(i)."
                return false
            end
            if i < length(path) - 1 && v_node_id in bundle.forbidden_nodes
                verbose &&
                    @warn "Bundle $(bundle_idx) path uses forbidden node $(v_node_id) at position $(i+1)."
                return false
            end

            # Check forbidden arcs
            if (u_node_id, v_node_id) in bundle.forbidden_arcs
                verbose &&
                    @warn "Bundle $(bundle_idx) path uses forbidden arc ($(u_node_id), $(v_node_id))."
                return false
            end
        end

        # Check start node: if it's exactly the expected code, accept immediately,
        # otherwise perform tolerant checks comparing spatial IDs and times.
        start_node_code = path[1]
        valid_origin = travel_time_graph.origin_codes[bundle_idx]
        if start_node_code != valid_origin
            start_label = MetaGraphsNext.label_for(travel_time_graph.graph, start_node_code)
            origin_label = MetaGraphsNext.label_for(travel_time_graph.graph, valid_origin)
            # Spatial must match
            if start_label[1] != origin_label[1]
                verbose &&
                    @warn "Bundle $(bundle_idx) starts at spatial node $(start_label[1]) instead of valid origin $(origin_label[1])."
                return false
            end
            # Time must be in a sensible range and respect semantics
            if is_date_arrival(travel_time_graph)
                # start τ must be <= origin τ (max duration)
                if start_label[2] > origin_label[2] || start_label[2] < 0
                    verbose &&
                        @warn "Bundle $(bundle_idx) starts at invalid time τ=$(start_label[2]) for arrival-mode origin (max τ=$(origin_label[2]))."
                    return false
                end
            else
                # elapsed-time: start τ must be >= origin τ (usually 0)
                if start_label[2] < origin_label[2] ||
                    start_label[2] > travel_time_graph.max_time_steps
                    verbose &&
                        @warn "Bundle $(bundle_idx) starts at invalid time τ=$(start_label[2]) for elapsed-mode origin (min τ=$(origin_label[2]))."
                    return false
                end
            end
        end

        # Check destination node (compare spatial IDs and time range)
        end_node_code = path[end]
        valid_destination = travel_time_graph.destination_codes[bundle_idx]
        end_label = MetaGraphsNext.label_for(travel_time_graph.graph, end_node_code)
        destination_label = MetaGraphsNext.label_for(
            travel_time_graph.graph, valid_destination
        )
        if end_node_code != valid_destination
            # Tolerant check: spatial ID must match and times must be within bounds
            if end_label[1] != destination_label[1]
                verbose &&
                    @warn "Bundle $(bundle_idx) ends at spatial node $(end_label[1]) instead of valid destination $(destination_label[1])."
                return false
            end
            if is_date_arrival(travel_time_graph)
                # arrival: must end at τ == destination τ (typically 0)
                if end_label[2] != destination_label[2]
                    verbose &&
                        @warn "Bundle $(bundle_idx) ends at time τ=$(end_label[2]) instead of expected $(destination_label[2]) for arrival-mode destination."
                    return false
                end
            else
                # elapsed: end τ must be <= destination τ (max duration) and >= 0
                if end_label[2] < 0 || end_label[2] > destination_label[2]
                    verbose &&
                        @warn "Bundle $(bundle_idx) ends at invalid time τ=$(end_label[2]) for elapsed-mode destination (max τ=$(destination_label[2]))."
                    return false
                end
            end
        end
    end

    # Capacity checks
    # 1) For bin-packing arcs, ensure no bin exceeds its capacity (remaining
    #    capacity < 0 within tolerance means total > max).
    for (edge, assignment) in sol.assignments
        for b in bins_of(assignment)
            if b.remaining_capacity < -tol
                verbose &&
                    @warn "Bin on edge $(edge) exceeds capacity by $(-b.remaining_capacity)"
                return false
            end
        end
    end

    # 2) For all time-space arcs, ensure commodity size fits arc capacity per mode.
    for (edge, assignment) in sol.assignments
        u, v = edge
        u_label = MetaGraphsNext.label_for(time_space_graph.graph, u)
        v_label = MetaGraphsNext.label_for(time_space_graph.graph, v)
        if MetaGraphsNext.haskey(time_space_graph.graph, u_label, v_label)
            arc = time_space_graph.graph[u_label, v_label]
            if !_capacity_feasible(arc, assignment, (u_label, v_label); verbose)
                return false
            end
        else
            verbose &&
                @warn "TimeSpaceGraph arc for edge $(edge) not found, cannot check capacity."
        end
    end

    return true
end

function _capacity_feasible(
    arc::NetworkArc, assignment::AbstractArcAssignment, arc_labels; verbose::Bool
)
    arc.capacity == typemax(Int) && return true
    total_size = total_size_of(assignment)
    if total_size > arc.capacity + 1e-8
        verbose &&
            @warn "Arc $(arc_labels) exceeds capacity: $(total_size) > $(arc.capacity)"
        return false
    end
    return true
end

function _capacity_feasible(
    arc::MultiModalArc, assignment::MultiAssignment, arc_labels; verbose::Bool
)
    for (i, (mode, slot)) in enumerate(zip(arc.modes, assignment.per_mode))
        mode.capacity == typemax(Int) && continue
        total_size = slot.total_size
        if total_size > mode.capacity + 1e-8
            verbose &&
                @warn "Arc $(arc_labels) mode $(i) exceeds capacity: $(total_size) > $(mode.capacity)"
            return false
        end
    end
    return true
end
