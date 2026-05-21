"""
$TYPEDSIGNATURES

Compute the additional cost of adding `new_commodities` to an arc that already contains
`existing_commodities`.
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

"""
$TYPEDSIGNATURES

Specialized for LinearArcCost for efficiency.
"""
function incremental_cost(
    arc_f::LinearArcCost, ::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    total_new_size = sum(c.size for c in new_commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_new_size
end

"""
$TYPEDSIGNATURES

For `NetworkArc` edges the selector is irrelevant (one mode) and the method just forwards to
`incremental_cost`.
"""
function _edge_incremental_cost(
    arc::NetworkArc, ::Nothing, new_comms::Vector{C}, ::AbstractModeSelector
) where {C<:LightCommodity}
    return incremental_cost(arc.cost, C[], new_comms)
end

"""
$TYPEDSIGNATURES

For `NetworkArc` edges the selector is irrelevant (one mode) and the method just forwards to
`incremental_cost`.
"""
function _edge_incremental_cost(
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector,
) where {C<:LightCommodity}
    return incremental_cost(arc.cost, existing.commodities, new_comms)
end

"""
$TYPEDSIGNATURES

For `MultiModalArc` edges and cheapest mode selector, compute the incremental cost of adding
to the cheapest feasible mode (or `Inf` if no single mode can accommodate the new commodities).
"""
function _edge_incremental_cost(
    arc::MultiModalArc, ::Nothing, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        if _mode_has_capacity(mode, C[], new_comms)
            incremental_cost(mode.cost, C[], new_comms)
        else
            Inf
        end for mode in arc.modes
    )
end

"""
$TYPEDSIGNATURES

For `MultiModalArc` edges and cheapest mode selector, compute the incremental cost of adding
to the cheapest feasible mode (or `Inf` if no single mode can accommodate the new commodities).
"""
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

"""
$TYPEDSIGNATURES

For `MultiModalArc` edges and fill-then-spill mode selector, we allow splitting over multiple modes
if the cheapest is full. The incremental cost is the sum of the increments on each mode.
"""
function _edge_incremental_cost(
    arc::MultiModalArc, ::Nothing, new_comms::Vector{C}, ::FillThenSpillMode
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

"""
$TYPEDSIGNATURES
"""
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
$TYPEDSIGNATURES

Compute the incremental cost of a TravelTimeGraph edge for a specific bundle,
considering all its orders and their projections to the TimeSpaceGraph.
"""
function compute_ttg_edge_incremental_cost(
    current_solution::Solution{C},
    instance::Instance,
    bundle::Bundle,
    u_ttg_code::Int,
    v_ttg_code::Int,
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
        existing_assignment = get(current_solution.assignments, edge, nothing)
        total_incremental_cost += _edge_incremental_cost(
            arc, existing_assignment, new_comms, mode_selector
        )
    end

    return total_incremental_cost
end

"""
$TYPEDSIGNATURES

Compute and overwrite the `TravelTimeGraph` cost matrix entries for every arc of bundle
`bundle_idx`, given the current solution state. Arcs forbidden for the bundle are set to `Inf`.
"""
function update_bundle_cost_matrix!(
    current_solution::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    ttg = instance.travel_time_graph
    bundle = instance.bundles[bundle_idx]

    for (u_code, v_code) in ttg.bundle_arcs[bundle_idx]
        u_node_id = MetaGraphsNext.label_for(ttg.graph, u_code)[1]
        v_node_id = MetaGraphsNext.label_for(ttg.graph, v_code)[1]

        if (u_node_id, v_node_id) in bundle.forbidden_arcs ||
            u_node_id in bundle.forbidden_nodes ||
            v_node_id in bundle.forbidden_nodes
            ttg.cost_matrix[u_code, v_code] = Inf
        else
            ttg.cost_matrix[u_code, v_code] = compute_ttg_edge_incremental_cost(
                current_solution, instance, bundle, u_code, v_code, mode_selector
            )
        end
    end
    return nothing
end
