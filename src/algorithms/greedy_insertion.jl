"""
    incremental_cost(arc_f::AbstractArcCostFunction, existing_commodities, new_commodities)

Compute the additional cost of adding `new_commodities` to an arc that already contains `existing_commodities`.
"""
function incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    # Default implementation: evaluate total and subtract
    all_commodities = vcat(existing_commodities, new_commodities)
    return evaluate(arc_f, all_commodities) - evaluate(arc_f, existing_commodities)
end

# Specialized for LinearArcCost for efficiency
function incremental_cost(
    arc_f::LinearArcCost, existing_commodities::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    total_new_size = sum(c.size for c in new_commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_new_size
end

# `_edge_incremental_cost` accepts a mode selector for uniform calling at the
# Dijkstra cost-evaluation site. For `NetworkArc` edges the selector is
# irrelevant (one mode) and the methods just forward to `incremental_cost`.
function _edge_incremental_cost(
    arc::NetworkArc, existing::Nothing, new_comms::Vector{C}, ::AbstractModeSelector
) where {C<:LightCommodity}
    return incremental_cost(arc.cost, C[], new_comms)
end

function _edge_incremental_cost(
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector,
) where {C<:LightCommodity}
    return incremental_cost(arc.cost, existing.commodities, new_comms)
end

function _edge_incremental_cost(
    arc::MultiModalArc, existing::Nothing, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(mode, C[], new_comms)
            incremental_cost(mode.cost, C[], new_comms)
        else
            Inf
        end for mode in arc.modes
    )
end

function _edge_incremental_cost(
    arc::MultiModalArc, existing::MultiAssignment{C}, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(arc.modes[i], existing.per_mode[i].commodities, new_comms)
            incremental_cost(
                arc.modes[i].cost, existing.per_mode[i].commodities, new_comms
            )
        else
            Inf
        end for i in eachindex(arc.modes)
    )
end

function _edge_incremental_cost(
    arc::MultiModalArc, existing::Nothing, new_comms::Vector{C}, ::FillThenSpillMode
) where {C<:LightCommodity}
    empty_existing = [C[] for _ in eachindex(arc.modes)]
    partition, overflow = _fill_then_spill_partition(arc, empty_existing, new_comms)
    overflow && return Inf
    total = 0.0
    for i in eachindex(arc.modes)
        isempty(partition[i]) && continue
        total += incremental_cost(arc.modes[i].cost, empty_existing[i], partition[i])
    end
    return total
end

function _edge_incremental_cost(
    arc::MultiModalArc,
    existing::MultiAssignment{C},
    new_comms::Vector{C},
    ::FillThenSpillMode,
) where {C<:LightCommodity}
    existing_per_mode = [slot.commodities for slot in existing.per_mode]
    partition, overflow = _fill_then_spill_partition(arc, existing_per_mode, new_comms)
    overflow && return Inf
    total = 0.0
    for i in eachindex(arc.modes)
        isempty(partition[i]) && continue
        total += incremental_cost(arc.modes[i].cost, existing_per_mode[i], partition[i])
    end
    return total
end

"""
    compute_ttg_edge_incremental_cost(sol, instance, bundle, u_ttg_label, v_ttg_label)

Compute the incremental cost of a TravelTimeGraph edge for a specific bundle,
considering all its orders and their projections to the TimeSpaceGraph.
"""
function compute_ttg_edge_incremental_cost(
    sol::Solution{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code,
    v_ttg_code,
    mode_selector::AbstractModeSelector=CheapestMode(),
) where {C}
    tsg = instance.time_space_graph

    # IF it's a shortcut arc, return zero cost
    u_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, u_ttg_code)
    v_ttg_label = MetaGraphsNext.label_for(instance.travel_time_graph.graph, v_ttg_code)
    if u_ttg_label[1] == v_ttg_label[1]
        return 0.0
    end

    # Collect all TSG edges affected by this TTG edge for this bundle
    # Many orders might map to the same TSG edge
    tsg_edge_to_new_commodities = Dict{Tuple{Int,Int},Vector{C}}()

    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        edge = (u_tsg, v_tsg)

        if !haskey(tsg_edge_to_new_commodities, edge)
            tsg_edge_to_new_commodities[edge] = C[]
        end
        append!(tsg_edge_to_new_commodities[edge], order.commodities)
    end

    total_incremental_cost = 0.0

    for (edge, new_comms) in tsg_edge_to_new_commodities
        u_tsg, v_tsg = edge
        u_tsg_label = MetaGraphsNext.label_for(tsg.graph, u_tsg)
        v_tsg_label = MetaGraphsNext.label_for(tsg.graph, v_tsg)

        if !MetaGraphsNext.haskey(tsg.graph, u_tsg_label, v_tsg_label)
            @warn "TSG edge ($u_tsg_label -> $v_tsg_label) does not exist!"
            return Inf # Infeasible for this bundle
        end

        arc = tsg.graph[u_tsg_label, v_tsg_label]
        existing_assignment = get(sol.assignments, edge, nothing)
        inc = _edge_incremental_cost(arc, existing_assignment, new_comms, mode_selector)
        total_incremental_cost += inc
    end

    return total_incremental_cost
end

"""
    insert_bundle!(sol, instance, bundle_idx)

Find the cheapest path for a bundle in the TravelTimeGraph (considering incremental costs)
and add it to the solution.
"""
function insert_bundle!(
    sol::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    ttg = instance.travel_time_graph
    bundle = instance.bundles[bundle_idx]

    for (u_code, v_code) in ttg.bundle_arcs[bundle_idx]
        # Get node IDs from TTG labels
        u_label = MetaGraphsNext.label_for(ttg.graph, u_code)
        v_label = MetaGraphsNext.label_for(ttg.graph, v_code)
        u_node_id = u_label[1]
        v_node_id = v_label[1]

        # Check forbidden constraints (O(1) lookups using Sets)
        is_arc_forbidden = (
            (u_node_id, v_node_id) in bundle.forbidden_arcs ||
            u_node_id in bundle.forbidden_nodes ||
            v_node_id in bundle.forbidden_nodes
        )

        if is_arc_forbidden
            # Skip cost computation for forbidden arcs, mark as infeasible
            ttg.cost_matrix[u_code, v_code] = Inf
        else
            # Compute incremental cost only for allowed arcs
            ttg.cost_matrix[u_code, v_code] = compute_ttg_edge_incremental_cost(
                sol, instance, bundle, u_code, v_code, mode_selector
            )
        end
    end

    origin = ttg.origin_codes[bundle_idx]
    destination = ttg.destination_codes[bundle_idx]

    res = Graphs.dijkstra_shortest_paths(ttg.graph, origin, ttg.cost_matrix)
    path = Graphs.enumerate_paths(res, destination)

    if isempty(path)
        throw(ArgumentError("No feasible path found for bundle $bundle_idx, ($path)"))
    end

    add_bundle_path!(sol, instance, bundle_idx, path; mode_selector)
    return nothing
end

"""
$TYPEDSIGNATURES

Construct a solution by inserting bundles one by one into an initially empty solution.
Bundles are processed in decreasing order of total size, so the heaviest bundles claim
their preferred paths first.

# Keyword arguments
- `mode_selector::AbstractModeSelector = CheapestMode()`: strategy that decides how
  a bundle's commodities are distributed across modes of a [`MultiModalArc`](@ref)
  (only relevant when several modes share the same transit time and therefore
  collapse to one edge). See [`CheapestMode`](@ref) and [`FillThenSpillMode`](@ref).

# Errors
Throws `ArgumentError` if no feasible path exists for a bundle. With
[`CheapestMode`](@ref), this can happen when no single mode on a required edge
has enough remaining capacity. With [`FillThenSpillMode`](@ref), it happens when
the combined capacity across all modes on a required edge is below the load.
"""
function greedy_heuristic(
    instance::Instance; mode_selector::AbstractModeSelector=CheapestMode()
)
    sol = Solution(instance)
    sorted_indices = sortperm(instance.bundles; by=total_size, rev=true)
    @showprogress for i in sorted_indices
        insert_bundle!(sol, instance, i, mode_selector)
    end
    return sol
end
