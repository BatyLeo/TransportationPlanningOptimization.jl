"""
$TYPEDSIGNATURES

Check if a solution is feasible for a given instance.
Feasibility requires:
1. Every bundle in the instance must have a corresponding path in the solution.
2. Every path must exist (each arc exists in the graph).
3. Every path is elementary: it never revisits a physical node after leaving it
   (waiting on the same node is allowed).
4. Every path must start at the bundle's designated entry node (`origin_codes`).
5. Every path must end at the bundle's designated exit node (`destination_codes`).
6. Every stored assignment sits on an existing arc and respects its capacity (per mode
   on multi-modal arcs).
7. Every bin is non-empty, respects the bin capacity of its arc cost, and the bins hold
   exactly the commodities of their assignment.
8. The assignments carry exactly the load of the bundle paths, plus any commodity
   belonging to no bundle of the instance (capacity reservations, see
   [`preload_filtered_bundles`](@ref)).
"""
function is_feasible(sol::SolutionState, instance::Instance; verbose::Bool=false, tol=EPS)
    (; travel_time_graph, time_space_graph) = instance
    if length(sol.bundle_paths) != length(instance.bundles)
        verbose &&
            @warn "SolutionState has $(length(sol.bundle_paths)) bundle paths for $(length(instance.bundles)) bundles."
        return false
    end
    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        if isempty(path)
            verbose && @warn "Bundle $(bundle_idx) has an empty path."
            return false
        end

        bundle = instance.bundles[bundle_idx]

        _check_path_edges(travel_time_graph, bundle, bundle_idx, path; verbose) ||
            return false
        _check_elementary_path(instance, bundle_idx, path; verbose) || return false
        _check_origin_node(travel_time_graph, bundle_idx, path; verbose) || return false
        _check_destination_node(travel_time_graph, bundle_idx, path; verbose) ||
            return false
    end

    # Capacity checks: bins and arc capacity per mode, for every stored assignment.
    for (edge, assignment) in sol.assignments
        u, v = edge
        arc = tsg_edge_arc(instance.index_cache, u, v)
        if isnothing(arc)
            verbose && @warn "TimeSpaceGraph arc for edge $(edge) not found."
            return false
        end
        arc_labels = (
            MetaGraphsNext.label_for(time_space_graph.graph, u),
            MetaGraphsNext.label_for(time_space_graph.graph, v),
        )
        _capacity_feasible(arc, assignment, arc_labels; tol, verbose) || return false
    end

    return _check_assignment_load(sol, instance; verbose)
end

"""
$TYPEDSIGNATURES

Check every edge of `path`: the arc exists in the graph, no intermediate node is
forbidden for the bundle, and no arc is forbidden. Origin and destination nodes
are validated separately by [`_check_origin_node`](@ref) /
[`_check_destination_node`](@ref).
"""
function _check_path_edges(
    ttg::TravelTimeGraph, bundle::Bundle, bundle_idx::Int, path::Vector{Int}; verbose::Bool
)
    for i in 1:(length(path) - 1)
        u, v = path[i], path[i + 1]
        if !Graphs.has_edge(ttg.graph, u, v)
            verbose && @warn "Arc ($(u), $(v)) in bundle $(bundle_idx) path does not exist."
            return false
        end

        # Forbidden checks use spatial node ids (intermediate nodes only; origin
        # and destination are validated separately).
        u_label = MetaGraphsNext.label_for(ttg.graph, u)
        v_label = MetaGraphsNext.label_for(ttg.graph, v)
        u_node_id = u_label[1]
        v_node_id = v_label[1]

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
        if (u_node_id, v_node_id) in bundle.forbidden_arcs
            verbose &&
                @warn "Bundle $(bundle_idx) path uses forbidden arc ($(u_node_id), $(v_node_id))."
            return false
        end
    end
    return true
end

"""
$TYPEDSIGNATURES

Check that `path` of bundle `bundle_idx` is elementary, see [`is_elementary_path`](@ref).
"""
function _check_elementary_path(
    instance::Instance, bundle_idx::Int, path::Vector{Int}; verbose::Bool
)
    spatial = instance.index_cache.ttg_code_to_spatial_code
    is_elementary_path(path, spatial) && return true
    if verbose
        ids = [
            MetaGraphsNext.label_for(instance.travel_time_graph.graph, v)[1] for v in path
        ]
        @warn "Bundle $(bundle_idx) path is not elementary, it revisits a physical node: $(ids)."
    end
    return false
end

"""
$TYPEDSIGNATURES

Check that `path` starts at bundle `bundle_idx`'s origin. If the start code is
exactly the expected origin, accept immediately; otherwise apply a tolerant
check comparing spatial IDs and respecting the graph's time semantics.
"""
function _check_origin_node(
    ttg::TravelTimeGraph, bundle_idx::Int, path::Vector{Int}; verbose::Bool
)
    start_node_code = path[1]
    valid_origin = ttg.origin_codes[bundle_idx]
    start_node_code == valid_origin && return true

    start_label = MetaGraphsNext.label_for(ttg.graph, start_node_code)
    origin_label = MetaGraphsNext.label_for(ttg.graph, valid_origin)
    # Spatial must match
    if start_label[1] != origin_label[1]
        verbose &&
            @warn "Bundle $(bundle_idx) starts at spatial node $(start_label[1]) instead of valid origin $(origin_label[1])."
        return false
    end
    # Time must be in a sensible range and respect semantics
    if is_date_arrival(ttg)
        # start τ must be <= origin τ (max duration)
        if start_label[2] > origin_label[2] || start_label[2] < 0
            verbose &&
                @warn "Bundle $(bundle_idx) starts at invalid time τ=$(start_label[2]) for arrival-mode origin (max τ=$(origin_label[2]))."
            return false
        end
    else
        # elapsed-time: start τ must be >= origin τ (usually 0)
        if start_label[2] < origin_label[2] || start_label[2] > ttg.max_time_steps
            verbose &&
                @warn "Bundle $(bundle_idx) starts at invalid time τ=$(start_label[2]) for elapsed-mode origin (min τ=$(origin_label[2]))."
            return false
        end
    end
    return true
end

"""
$TYPEDSIGNATURES

Check that `path` ends at bundle `bundle_idx`'s destination. If the end code is
exactly the expected destination, accept immediately; otherwise apply a tolerant
check comparing spatial IDs and respecting the graph's time semantics.
"""
function _check_destination_node(
    ttg::TravelTimeGraph, bundle_idx::Int, path::Vector{Int}; verbose::Bool
)
    end_node_code = path[end]
    valid_destination = ttg.destination_codes[bundle_idx]
    end_node_code == valid_destination && return true

    end_label = MetaGraphsNext.label_for(ttg.graph, end_node_code)
    destination_label = MetaGraphsNext.label_for(ttg.graph, valid_destination)
    # Spatial ID must match
    if end_label[1] != destination_label[1]
        verbose &&
            @warn "Bundle $(bundle_idx) ends at spatial node $(end_label[1]) instead of valid destination $(destination_label[1])."
        return false
    end
    if is_date_arrival(ttg)
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
    return true
end

"""
$TYPEDSIGNATURES

Check the bins of `slot` against the bin capacity of `arc_cost`: no bin is overloaded
or empty, and the bins hold exactly the commodities of the slot.
Always true when `arc_cost` has no bin-packing component.
"""
function _bins_feasible(slot::SingleAssignment, arc_cost, arc_labels; tol, verbose::Bool)
    bp = _bin_packing_cost_of(arc_cost)
    isnothing(bp) && return true
    for b in slot.bins
        if isempty(b.commodities)
            verbose && @warn "Arc $(arc_labels) has an empty bin"
            return false
        end
        load = sum(c.size for c in b.commodities; init=0.0)
        if load > bp.bin_capacity + tol
            verbose &&
                @warn "Arc $(arc_labels) has a bin exceeding capacity: $(load) > $(bp.bin_capacity)"
            return false
        end
    end
    if sum(length(b.commodities) for b in slot.bins; init=0) != length(slot.commodities)
        verbose &&
            @warn "Arc $(arc_labels) has bins that do not hold exactly its commodities"
        return false
    end
    binned = Dict{eltype(slot.commodities),Int}()
    for b in slot.bins, c in b.commodities
        binned[c] = get(binned, c, 0) + 1
    end
    for c in slot.commodities
        binned[c] = get(binned, c, 0) - 1
    end
    if any(!iszero, values(binned))
        verbose &&
            @warn "Arc $(arc_labels) has bins that do not hold exactly its commodities"
        return false
    end
    return true
end

function _capacity_feasible(
    arc::NetworkArc, assignment::SingleAssignment, arc_labels; tol, verbose::Bool
)
    _bins_feasible(assignment, arc.cost, arc_labels; tol, verbose) || return false
    arc.capacity == typemax(Int) && return true
    total_size = total_size_of(assignment)
    if total_size > arc.capacity + tol
        verbose &&
            @warn "Arc $(arc_labels) exceeds capacity: $(total_size) > $(arc.capacity)"
        return false
    end
    return true
end

function _capacity_feasible(
    arc::MultiModalArc, assignment::MultiAssignment, arc_labels; tol, verbose::Bool
)
    if length(assignment.per_mode) != length(arc.modes)
        verbose &&
            @warn "Arc $(arc_labels) has $(length(arc.modes)) modes but the assignment has $(length(assignment.per_mode)) slots"
        return false
    end
    for (i, (mode, slot)) in enumerate(zip(arc.modes, assignment.per_mode))
        _bins_feasible(slot, mode.cost, arc_labels; tol, verbose) || return false
        mode.capacity == typemax(Int) && continue
        total_size = slot.total_size
        if total_size > mode.capacity + tol
            verbose &&
                @warn "Arc $(arc_labels) mode $(i) exceeds capacity: $(total_size) > $(mode.capacity)"
            return false
        end
    end
    return true
end

# The assignment shape does not match the arc (e.g. a `MultiAssignment` on a single-mode arc).
function _capacity_feasible(
    arc::AbstractNetworkArc,
    assignment::AbstractArcAssignment,
    arc_labels;
    tol,
    verbose::Bool,
)
    verbose &&
        @warn "Arc $(arc_labels) of type $(typeof(arc)) cannot hold an assignment of type $(typeof(assignment))"
    return false
end

"""
$TYPEDSIGNATURES

Check that the stored assignments carry exactly the commodities that the bundle paths
of `sol` route over each time-space edge (same projection as [`add_bundle_path!`](@ref)).
Commodities owned by no bundle of `instance` (reservations) are ignored.
"""
function _check_assignment_load(
    sol::SolutionState{C}, instance::Instance; verbose::Bool
) where {C}
    owned = Set{C}(
        c for bundle in instance.bundles for o in bundle.orders for c in o.commodities
    )
    balance = Dict{Tuple{Tuple{Int,Int},C},Int}()
    sizehint!(
        balance,
        sum(a -> count(Returns(true), commodities_of(a)), values(sol.assignments); init=0),
    )
    for (edge, assignment) in sol.assignments
        for c in commodities_of(assignment)
            c in owned || continue
            key = (edge, c)
            balance[key] = get(balance, key, 0) + 1
        end
    end
    for (bundle, path) in zip(instance.bundles, sol.bundle_paths)
        stripped = copy(path)
        _remove_shortcuts_from_path!(stripped, instance.travel_time_graph)
        _foreach_path_edge(instance, bundle, stripped) do edge, _, order
            for c in order.commodities
                key = (edge, c)
                balance[key] = get(balance, key, 0) - 1
            end
            return 0.0
        end
    end
    for ((edge, c), n) in balance
        iszero(n) && continue
        if verbose
            labels = map(
                code -> MetaGraphsNext.label_for(instance.time_space_graph.graph, code),
                edge,
            )
            @warn "Edge $(labels) carries $(abs(n)) $(n > 0 ? "more" : "fewer") copies of $(c) than its bundle paths route"
        end
        return false
    end
    return true
end
