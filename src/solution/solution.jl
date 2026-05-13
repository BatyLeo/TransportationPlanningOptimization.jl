"""
$TYPEDEF

A solution to the network design optimization problem.
It stores the chosen paths for each bundle in the `TravelTimeGraph` and precomputes
key metrics such as commodity distributions on arcs and individual arc costs.

# Fields
$TYPEDFIELDS
"""
struct Solution{C<:LightCommodity}
    "Paths for each bundle in the instance. `bundle_paths[i]` is a sequence of node codes in the `TravelTimeGraph` for the i-th bundle."
    bundle_paths::Vector{Vector{Int}}
    "Per-edge assignment payload, keyed by `(u_tsg_code, v_tsg_code)`. Values are `SingleAssignment{C}` for single-mode edges and `MultiAssignment{C}` for multi-modal edges. The 2-element union lets Julia apply union-splitting at all dispatch sites."
    assignments::Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}
end

function Base.show(io::IO, sol::Solution)
    nb_trucks = sum(length(bins_of(a)) for a in values(sol.assignments); init=0)
    return print(io, "Solution(num_trucks=$(nb_trucks), assignments=$(sol.assignments))")
end

"""
    Solution(instance::Instance)

Initialize an empty solution for the given instance.
"""
function Solution(instance::Instance{Bundle{Order{IDA,I}}}) where {IDA,I}
    C = LightCommodity{IDA,I}
    return Solution{C}(
        [Int[] for _ in 1:bundle_count(instance)],
        Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}(),
    )
end

"""
$TYPEDSIGNATURES

Check if a solution is feasible for a given instance.
Feasibility requires:
1. Every bundle in the instance must have a corresponding path in the solution.
2. Every path must exist (each arc exists in the graph).
3. Every path must start at the bundle's designated entry node (`origin_codes`).
4. Every path must end at the bundle's designated exit node (`destination_codes`).
"""
function is_feasible(sol::Solution, instance::Instance; verbose::Bool=false)
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

    # Capacity checks ------------------------------------------------------
    # 1) For bin-packing arcs, ensure no bin exceeds its capacity.
    for (edge, assignment) in sol.assignments
        for b in bins_of(assignment)
            if b.total_size > b.max_capacity + 1e-8
                verbose &&
                    @warn "Bin on edge $(edge) exceeds capacity: $(b.total_size) > $(b.max_capacity)"
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
                @warn "TimeSpaceGraph arc for edge $(edge) not found; cannot check capacity."
        end
    end

    return true
end

"""
$TYPEDSIGNATURES

Project a node code from the `TravelTimeGraph` to a node code in the `TimeSpaceGraph` for a specific order.
The projection converts the graph-specific time `τ` (budget or elapsed) into absolute time `t` in the `TimeSpaceGraph`.

# Time Projection Formulas
- If `is_date_arrival = true`: `t = deadline - τ`
- If `is_date_arrival = false`: `t = release + τ`

Throws a `DomainError` if the resulting `t` is outside the instance time horizon `[1, time_horizon_length]`.
"""
function project_to_time_space_graph(
    ttg_node_code::Int, order::Order{is_date_arrival}, instance::Instance
) where {is_date_arrival}
    (; time_space_graph, travel_time_graph) = instance
    u_label, τ = MetaGraphsNext.label_for(travel_time_graph.graph, ttg_node_code)

    if is_date_arrival
        t = order.time_step - τ
    else
        t = order.time_step + τ
    end

    wrap_time = time_space_graph.wrap_time

    if !(1 <= t <= instance.time_horizon_length)
        if wrap_time
            if t > instance.time_horizon_length
                t = t - instance.time_horizon_length
            else
                t = t + instance.time_horizon_length
            end
        else
            throw(
                DomainError(
                    t,
                    "Projected time step out of bounds (τ=$(τ), t=$(t)) for order $(order) and node code $(ttg_node_code) u_label=$(u_label)",
                ),
            )
        end
    end

    tsg_node_label = (u_label, t)
    return MetaGraphsNext.code_for(time_space_graph.graph, tsg_node_label)
end

"""
$TYPEDSIGNATURES

Project bundle paths to order paths on the Time Space Graph.
Returns a Dict mapping Order to a Vector of TSG node codes (Int).
"""
function project_bundle_path_to_order_paths(sol::Solution, instance::Instance)
    order_paths = Dict{Order,Vector{Int}}()

    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        bundle = instance.bundles[bundle_idx]
        for order in bundle.orders
            tsg_path = [
                project_to_time_space_graph(node_code, order, instance) for
                node_code in path
            ]
            order_paths[order] = tsg_path
        end
    end
    return order_paths
end

"""
$TYPEDSIGNATURES

Incrementally add a path (sequence of TTG node codes) for a bundle and update the solution.
This updates `bundle_paths` and the per-edge entries in `assignments`.
"""
function _is_shortcut_arc(arc::NetworkArc)
    return false
end

function _is_shortcut_arc(arc::NetworkArc{ShortcutArcCost,K}) where {K}
    return travel_time_steps(arc) == 0
end

_is_shortcut_arc(arc::MultiModalArc) = false

function _update_single_assignment_cost!(
    slot::SingleAssignment{C}, arc_cost::AbstractArcCostFunction
) where {C}
    if arc_cost isa BinPackingArcCost
        bins = compute_bin_assignments(arc_cost, slot.commodities)
        slot.bins = bins
        slot.cost = arc_cost.cost_per_bin * length(bins)
    else
        slot.cost = evaluate(arc_cost, slot.commodities)
    end
    return nothing
end

function _fill_then_spill_partition(
    arc::MultiModalArc, existing_per_mode::Vector{Vector{C}}, new_comms::Vector{C}
) where {C<:LightCommodity}
    mode_costs = [
        incremental_cost(arc.modes[i].cost, existing_per_mode[i], new_comms) for
        i in eachindex(arc.modes)
    ]
    sorted_indices = sortperm(mode_costs)

    per_mode_new = [C[] for _ in eachindex(arc.modes)]
    remaining = copy(new_comms)

    for mode_idx in sorted_indices
        isempty(remaining) && break
        mode = arc.modes[mode_idx]
        existing_size = sum(c.size for c in existing_per_mode[mode_idx]; init=0.0)
        cap_left = Float64(mode.capacity) - existing_size

        placed = C[]
        still_remaining = C[]
        placed_size = 0.0

        for c in remaining
            if placed_size + c.size <= cap_left + 1e-8
                push!(placed, c)
                placed_size += c.size
            else
                push!(still_remaining, c)
            end
        end

        per_mode_new[mode_idx] = placed
        remaining = still_remaining
    end

    if !isempty(remaining)
        append!(per_mode_new[sorted_indices[end]], remaining)
    end

    return per_mode_new
end

function _fill_then_spill_assign!(
    arc::MultiModalArc, assignment::MultiAssignment{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    existing_per_mode = [commodities_of(slot) for slot in assignment.per_mode]
    partition = _fill_then_spill_partition(arc, existing_per_mode, new_commodities)
    for (i, placed) in enumerate(partition)
        isempty(placed) && continue
        slot = assignment.per_mode[i]
        append!(slot.commodities, placed)
        _update_single_assignment_cost!(slot, arc.modes[i].cost)
    end
    return nothing
end

function _add_order_to_assignment!(
    assignments::Dict{Tuple{Int,Int},<:AbstractArcAssignment{C}},
    edge::Tuple{Int,Int},
    arc::NetworkArc,
    new_commodities::Vector{C};
    mode_selection::Symbol=:cheapest,
) where {C<:LightCommodity}
    assignment = get!(assignments, edge) do
        SingleAssignment{C}()
    end::SingleAssignment{C}
    append!(assignment.commodities, new_commodities)
    _update_single_assignment_cost!(assignment, arc.cost)
    return nothing
end

function _add_order_to_assignment!(
    assignments::Dict{Tuple{Int,Int},<:AbstractArcAssignment{C}},
    edge::Tuple{Int,Int},
    arc::MultiModalArc,
    new_commodities::Vector{C};
    mode_selection::Symbol=:cheapest,
) where {C<:LightCommodity}
    assignment = get!(assignments, edge) do
        MultiAssignment{C}(length(arc.modes))
    end::MultiAssignment{C}
    if mode_selection == :fill_then_spill
        _fill_then_spill_assign!(arc, assignment, new_commodities)
    else
        best_mode_idx = argmin(
            incremental_cost(
                arc.modes[i].cost, commodities_of(assignment.per_mode[i]), new_commodities
            ) for i in eachindex(arc.modes)
        )
        slot = assignment.per_mode[best_mode_idx]
        append!(slot.commodities, new_commodities)
        _update_single_assignment_cost!(slot, arc.modes[best_mode_idx].cost)
    end
    return nothing
end

function _capacity_feasible(
    arc::NetworkArc, assignment::AbstractArcAssignment, arc_labels; verbose::Bool
)
    arc.capacity == typemax(Int) && return true
    total_size = sum(c.size for c in commodities_of(assignment); init=0.0)
    if total_size > arc.capacity + 1e-8
        verbose &&
            @warn "Arc $(arc_labels) exceeds capacity: $(total_size) > $(arc.capacity)"
        return false
    end
    return true
end

function _capacity_feasible(
    arc::MultiModalArc, assignment::AbstractArcAssignment, arc_labels; verbose::Bool
)
    # Per-mode capacity can only be checked when per-mode slots are available.
    assignment isa MultiAssignment || return true
    for (i, (mode, slot)) in enumerate(zip(arc.modes, assignment.per_mode))
        mode.capacity == typemax(Int) && continue
        total_size = sum(c.size for c in commodities_of(slot); init=0.0)
        if total_size > mode.capacity + 1e-8
            verbose &&
                @warn "Arc $(arc_labels) mode $(i) exceeds capacity: $(total_size) > $(mode.capacity)"
            return false
        end
    end
    return true
end

function _remove_shortcuts_from_path!(path::Vector{Int}, ttg::TravelTimeGraph)
    # Remove leading shortcuts for arrival-based graphs, trailing for elapsed-time graphs
    if length(path) < 2
        return nothing
    end

    if is_date_arrival(ttg)
        # Remove destination nodes of starting shortcut edges (keep the first timed node)
        while length(path) >= 2
            src, dst = path[1], path[2]
            u_label = MetaGraphsNext.label_for(ttg.graph, src)
            v_label = MetaGraphsNext.label_for(ttg.graph, dst)
            if !haskey(ttg.graph, u_label, v_label)
                break
            end
            arc = ttg.graph[u_label, v_label]
            # Only remove if the arc is a shortcut AND stays on the same spatial node
            if _is_shortcut_arc(arc) && u_label[1] == v_label[1]
                # Remove the leading node so the path starts at the first valid timed
                # node (consistent with existing `remove_shortcuts!` behaviour)
                deleteat!(path, 1)
            else
                break
            end
        end
    else
        # Remove destination nodes of trailing shortcut edges (pop trailing shortcut nodes)
        while length(path) >= 2
            src, dst = path[end - 1], path[end]
            u_label = MetaGraphsNext.label_for(ttg.graph, src)
            v_label = MetaGraphsNext.label_for(ttg.graph, dst)
            if !haskey(ttg.graph, u_label, v_label)
                break
            end
            arc = ttg.graph[u_label, v_label]
            if _is_shortcut_arc(arc) && u_label[1] == v_label[1]
                pop!(path) # remove trailing shortcut node
            else
                break
            end
        end
    end
    return nothing
end

function add_bundle_path!(
    sol::Solution{C},
    instance::Instance,
    bundle_idx::Int,
    path::Vector{Int};
    mode_selection::Symbol=:cheapest,
) where {C}
    # Remove potential shortcut edges before storing the path — TTG may contain shortcuts
    _remove_shortcuts_from_path!(path, instance.travel_time_graph)
    sol.bundle_paths[bundle_idx] = path
    bundle = instance.bundles[bundle_idx]
    tsg = instance.time_space_graph

    # For each order in the bundle, project and update
    for order in bundle.orders
        tsg_path = [
            project_to_time_space_graph(node_code, order, instance) for node_code in path
        ]
        for i in 1:(length(tsg_path) - 1)
            u, v = tsg_path[i], tsg_path[i + 1]
            edge = (u, v)
            u_label = MetaGraphsNext.label_for(tsg.graph, u)
            v_label = MetaGraphsNext.label_for(tsg.graph, v)
            arc = tsg.graph[u_label, v_label]
            _add_order_to_assignment!(
                sol.assignments, edge, arc, order.commodities; mode_selection
            )
        end
    end
    return nothing
end

"""
    Solution(bundle_paths, instance; mode_selection=:cheapest)

Construct a `Solution` from bundle paths and an instance.
This constructor precomputes commodity distributions on arcs, bin-packing results, and total cost.
"""
function Solution(
    bundle_paths::Vector{Vector{Int}},
    instance::Instance{Bundle{Order{IDA,I}}};
    mode_selection::Symbol=:cheapest,
) where {IDA,I}
    (; time_space_graph, bundles) = instance

    C = LightCommodity{IDA,I}
    assignments = Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}()

    # Clean paths (remove TTG shortcut edges) before projecting
    cleaned_paths = [copy(p) for p in bundle_paths]
    for (bundle_idx, ttg_path) in enumerate(cleaned_paths)
        _remove_shortcuts_from_path!(ttg_path, instance.travel_time_graph)
        bundle = bundles[bundle_idx]

        for order in bundle.orders
            tsg_path = [
                project_to_time_space_graph(node_code, order, instance) for
                node_code in ttg_path
            ]

            for i in 1:(length(tsg_path) - 1)
                u, v = tsg_path[i], tsg_path[i + 1]
                edge = (u, v)
                u_label = MetaGraphsNext.label_for(time_space_graph.graph, u)
                v_label = MetaGraphsNext.label_for(time_space_graph.graph, v)
                if !MetaGraphsNext.haskey(time_space_graph.graph, u_label, v_label)
                    @warn "Arc ($u_label, $v_label) not found in TimeSpaceGraph"
                    continue
                end
                arc = time_space_graph.graph[u_label, v_label]
                _add_order_to_assignment!(
                    assignments, edge, arc, order.commodities; mode_selection
                )
            end
        end
    end

    return Solution{C}(cleaned_paths, assignments)
end

"""
    cost(sol)

Compute the cost of the solution by summing individual arc costs.
"""
function cost(sol::Solution)
    return sum(cost_of(a) for a in values(sol.assignments); init=0.0)
end

"""
$TYPEDSIGNATURES

Compute the cost of the solution (legacy signature for compatibility).
"""
function cost(sol::Solution, instance::Instance)
    return cost(sol)
end
