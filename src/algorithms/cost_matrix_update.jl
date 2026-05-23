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

Lower-bound variant of `incremental_cost`. By default it forwards to
`incremental_cost`, so any new `AbstractArcCostFunction` subtype automatically
inherits a sane default. Specialize this for cost functions whose lower bound
differs from their actual cost (for example, `BinPackingArcCost`).
"""
function lower_bound_incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing_commodities, new_commodities)
end

"""
$TYPEDSIGNATURES

Lower-bound cost on a `BinPackingArcCost` arc using fractional bin counts
(no ceiling). The result is a continuous relaxation of the FFD cost. It is
not the cheapest path for an actual solver, but it is a valid lower bound
when summed across paths and used for filtering.
"""
function lower_bound_incremental_cost(
    arc_f::BinPackingArcCost, existing_commodities::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    existing_size = sum(c.size for c in existing_commodities; init=0.0)
    new_size = sum(c.size for c in new_commodities; init=0.0)
    n_bins_with = (existing_size + new_size) / arc_f.bin_capacity
    n_bins_without = existing_size / arc_f.bin_capacity
    return arc_f.cost_per_bin * (n_bins_with - n_bins_without)
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

function _edge_lower_bound_cost(
    arc::NetworkArc, ::Nothing, new_comms::Vector{C}, ::AbstractModeSelector
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(arc.cost, C[], new_comms)
end

function _edge_lower_bound_cost(
    arc::NetworkArc,
    existing::SingleAssignment{C},
    new_comms::Vector{C},
    ::AbstractModeSelector,
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(arc.cost, existing.commodities, new_comms)
end

function _edge_lower_bound_cost(
    arc::MultiModalArc, ::Nothing, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        lower_bound_incremental_cost(mode.cost, C[], new_comms) for mode in arc.modes
    )
end

function _edge_lower_bound_cost(
    arc::MultiModalArc, existing::MultiAssignment{C}, new_comms::Vector{C}, ::CheapestMode
) where {C<:LightCommodity}
    return minimum(
        lower_bound_incremental_cost(
            arc.modes[i].cost, existing.per_mode[i].commodities, new_comms
        ) for i in eachindex(arc.modes)
    )
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

Compute the incremental cost of a TTG edge under the lower-bound relaxation.
Same projection logic as `compute_ttg_edge_incremental_cost`, but with
`_edge_lower_bound_cost` substituted for `_edge_incremental_cost`.

When the TTG edge is the bundle's direct arc (spatial labels equal to
`(bundle.origin_id, bundle.destination_id)`), the per-order ceil rule is
applied instead of the fractional formula. This matches Renault's
`get_lb_transport_units`: a direct arc cannot be shared with other bundles,
so the fractional relaxation describes a fiction there, and the tighter
per-order ceil bound steers Dijkstra toward multi-hop consolidation when it
exists.
"""
function compute_ttg_edge_lower_bound_cost(
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

    # Direct arc dispatch: bundle's origin -> destination.
    if u_ttg_label[1] == bundle.origin_id && v_ttg_label[1] == bundle.destination_id
        return _direct_arc_lb_cost(bundle, instance, u_ttg_code, v_ttg_code, mode_selector)
    end

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

    total = 0.0
    for (edge, new_comms) in tsg_edge_to_new_commodities
        u_tsg, v_tsg = edge
        u_label = MetaGraphsNext.label_for(tsg.graph, u_tsg)
        v_label = MetaGraphsNext.label_for(tsg.graph, v_tsg)
        if !MetaGraphsNext.haskey(tsg.graph, u_label, v_label)
            @warn "TSG edge ($u_label -> $v_label) does not exist!"
            return Inf
        end
        arc = tsg.graph[u_label, v_label]
        existing = get(current_solution.assignments, edge, nothing)
        total += _edge_lower_bound_cost(arc, existing, new_comms, mode_selector)
    end
    return total
end

"""
$TYPEDSIGNATURES

Lower-bound cost for the bundle's direct arc, summed per order. Mirrors
Renault's `get_lb_transport_units` for `:direct` arcs: each order contributes
`ceil(order_size / bin_capacity) * cost_per_bin` on bin-packing arcs (or
`cost_per_unit_size * order_size` on linear arcs). Existing arc state is
ignored, matching STP behavior. Used internally by
`compute_ttg_edge_lower_bound_cost` when the TTG edge is identified as the
bundle's direct arc.
"""
function _direct_arc_lb_cost(
    bundle::Bundle,
    instance::Instance,
    u_ttg_code::Int,
    v_ttg_code::Int,
    mode_selector::AbstractModeSelector,
)
    tsg = instance.time_space_graph
    total = 0.0
    for order in bundle.orders
        u_tsg = project_to_time_space_graph(u_ttg_code, order, instance)
        v_tsg = project_to_time_space_graph(v_ttg_code, order, instance)
        u_label = MetaGraphsNext.label_for(tsg.graph, u_tsg)
        v_label = MetaGraphsNext.label_for(tsg.graph, v_tsg)
        if !MetaGraphsNext.haskey(tsg.graph, u_label, v_label)
            @warn "TSG edge ($u_label -> $v_label) does not exist!"
            return Inf
        end
        arc = tsg.graph[u_label, v_label]
        order_size = sum(c.size for c in order.commodities; init=0.0)
        total += _direct_arc_order_lb_cost(arc, order_size, mode_selector)
    end
    return total
end

function _direct_arc_order_lb_cost(
    arc::NetworkArc, order_size::Real, ::AbstractModeSelector
)
    return _direct_arc_order_lb_cost(arc.cost, order_size)
end

function _direct_arc_order_lb_cost(cost::BinPackingArcCost, order_size::Real)
    return cost.cost_per_bin * ceil(order_size / cost.bin_capacity)
end

function _direct_arc_order_lb_cost(cost::LinearArcCost, order_size::Real)
    return cost.cost_per_unit_size * order_size
end

function _direct_arc_order_lb_cost(
    arc::MultiModalArc, order_size::Real, ::AbstractModeSelector
)
    return minimum(_direct_arc_order_lb_cost(mode.cost, order_size) for mode in arc.modes)
end

"""
$TYPEDSIGNATURES

Compute and overwrite the `TravelTimeGraph` cost matrix entries for every arc of bundle
`bundle_idx`, given the current solution state. Arcs forbidden for the bundle are set to `Inf`.

All edges in the cost matrix are first reset to `Inf` so that Dijkstra cannot follow
edges outside `bundle_arcs[bundle_idx]` (which would otherwise retain stale values from
previous bundles' updates, or initial zeros from `TravelTimeGraph` construction).

The `cost_fn` keyword selects which per-edge cost computation is used. The default,
`compute_ttg_edge_incremental_cost`, preserves greedy behaviour. Lower-bound callers
can pass `cost_fn=compute_ttg_edge_lower_bound_cost`.
"""
function update_bundle_cost_matrix!(
    current_solution::Solution,
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector=CheapestMode();
    cost_fn::Function=compute_ttg_edge_incremental_cost,
)
    ttg = instance.travel_time_graph
    bundle = instance.bundles[bundle_idx]

    # Reset all edges to Inf. Restricts Dijkstra to `bundle_arcs[bundle_idx]`.
    fill!(SparseArrays.nonzeros(ttg.cost_matrix), Inf)

    for (u_code, v_code) in ttg.bundle_arcs[bundle_idx]
        u_node_id = MetaGraphsNext.label_for(ttg.graph, u_code)[1]
        v_node_id = MetaGraphsNext.label_for(ttg.graph, v_code)[1]

        if (u_node_id, v_node_id) in bundle.forbidden_arcs ||
            u_node_id in bundle.forbidden_nodes ||
            v_node_id in bundle.forbidden_nodes
            ttg.cost_matrix[u_code, v_code] = Inf
        else
            ttg.cost_matrix[u_code, v_code] = cost_fn(
                current_solution, instance, bundle, u_code, v_code, mode_selector
            )
        end
    end
    return nothing
end
