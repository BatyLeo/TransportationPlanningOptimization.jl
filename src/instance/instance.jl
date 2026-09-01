"""
$TYPEDEF

An `Instance` represents a transportation planning problem instance, containing bundles of
orders, a network graph, and a time horizon.

# Fields
$TYPEDFIELDS
"""
@kwdef struct Instance{
    B<:Bundle,G<:NetworkGraph,TSG<:TimeSpaceGraph,TTG<:TravelTimeGraph,IC<:IndexCache
}
    "list of bundles in the instance"
    bundles::Vector{B}
    "underlying network graph"
    network_graph::G
    "length of the time horizon in discrete time steps"
    time_horizon_length::Int
    "discretization time step for the instance"
    time_step::Period
    "mapping from time step index to date"
    time_step_to_date::Vector{Dates.Date}
    "time expanded graph (for order paths)"
    time_space_graph::TSG
    "travel time graph (for bundle paths)"
    travel_time_graph::TTG
    "precomputed integer-indexed lookup tables for the construction hot path"
    index_cache::IC
end

"""
$TYPEDSIGNATURES

Return the number of bundles in the instance.
"""
function bundle_count(instance::Instance)
    return length(instance.bundles)
end

"""
$TYPEDSIGNATURES

Return the number of orders in the instance.
"""
function order_count(instance::Instance)
    return sum(length(bundle.orders) for bundle in instance.bundles)
end

"""
$TYPEDSIGNATURES

Return the number of commodities in the instance.
"""
function commodity_count(instance::Instance)
    return sum(
        length(order.commodities) for bundle in instance.bundles for order in bundle.orders
    )
end

"""
$TYPEDSIGNATURES

Return a summary of the instance.
"""
function Base.show(io::IO, instance::Instance)
    nb_orders = order_count(instance)
    nb_commodities = commodity_count(instance)
    padding = length(string(nb_commodities))
    println(io, "Instance Summary:")
    println(
        io,
        "  • Horizon: $(instance.time_horizon_length) time steps ($(instance.time_step) per step)",
    )
    println(io, "  • Commodities: $(lpad(nb_commodities, padding))")
    println(io, "  • Orders:      $(lpad(nb_orders, padding))")
    println(io, "  • Bundles:     $(lpad(bundle_count(instance), padding))")
    print(io, "  • ", instance.network_graph)
    print(io, "  • ", instance.time_space_graph)
    print(io, "  • ", instance.travel_time_graph)
    return nothing
end

"""
$TYPEDSIGNATURES

Return the time horizon of the instance as a range of discrete time steps.
"""
function time_horizon(instance::Instance)
    return 1:(instance.time_horizon_length)
end

"""
$TYPEDSIGNATURES

Default grouping key for commodities: `nothing`, meaning no grouping beyond origin,
destination, and time step.
"""
function _default_group_by(::Commodity)
    return nothing
end

"""
$TYPEDSIGNATURES

Compute the calendar date that anchors time step 1 of the instance's discrete horizon.
All time step indices and `time_step_to_date` entries are measured as offsets from this date.

The chosen date is the earliest relevant date across all commodities, where "relevant"
depends on the time semantics (`is_date_arrival`):
- Arrival-based (`c.date` is a delivery deadline): the earliest deadline, or when
`wrap_time=false`, the earliest deadline minus its `max_delivery_time` so the horizon
reaches back far enough to cover the earliest possible departure.
- Departure-based (`c.date` is a release date): the earliest release date.
"""
function _compute_start_date(
    commodities::Vector{Commodity{is_date_arrival,ID,I}}, wrap_time::Bool
) where {is_date_arrival,ID,I}
    if is_date_arrival
        # Arrival-based: start date is min of arrival dates (- max delivery times)
        return if wrap_time
            minimum(Dates.Date(c.date) for c in commodities)
        else
            # Need to extend the time horizon to account for max delivery times, if no wrapping
            minimum(Dates.Date(c.date - c.max_delivery_time) for c in commodities)
        end
    else
        # Departure-based: start date is min of departure dates
        return minimum(Dates.Date(c.date) for c in commodities)
    end
end

"""
$TYPEDSIGNATURES

Expand each `Commodity` into `LightCommodity` items and group them into `Order`s keyed by
`(time_step_idx, origin_id, destination_id, group_by(commodity))`.

Returns `(order_dict, time_horizon_length, start_date)`, where `order_dict` maps each key to
a `(commodities, min_transit_steps)` tuple, and `time_horizon_length` accounts for
`max_delivery_time` unless `wrap_time=true`.
"""
function _expand_commodities(
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period,
    group_by,
    wrap_time::Bool,
) where {is_date_arrival,ID,I}
    total_quantity = sum(c.quantity for c in commodities)
    full_commodities = LightCommodity{I}[]
    sizehint!(full_commodities, total_quantity)

    first_key = (
        1, commodities[1].origin_id, commodities[1].destination_id, group_by(commodities[1])
    )
    order_dict = Dict{typeof(first_key),Tuple{Vector{LightCommodity{I}},Int}}()

    start_date = _compute_start_date(commodities, wrap_time)

    for commodity in commodities
        light_commodity = LightCommodity(;
            origin_id=commodity.origin_id,
            destination_id=commodity.destination_id,
            size=commodity.size,
            info=commodity.info,
        )

        light_commodities_start_idx = length(full_commodities) + 1
        for _ in 1:(commodity.quantity)
            push!(full_commodities, light_commodity)
        end
        light_commodities_end_idx = length(full_commodities)

        max_transit_steps = period_steps(
            commodity.max_delivery_time, time_step; roundup=floor
        )
        time_step_idx =
            period_steps(
                Dates.Date(commodity.date) - start_date, time_step; roundup=floor
            ) + 1
        key = (
            time_step_idx,
            commodity.origin_id,
            commodity.destination_id,
            group_by(commodity),
        )

        to_append = view(
            full_commodities, light_commodities_start_idx:light_commodities_end_idx
        )

        if haskey(order_dict, key)
            commodities_list, min_steps = order_dict[key]
            append!(commodities_list, to_append)
            order_dict[key] = (commodities_list, min(min_steps, max_transit_steps))
        else
            order_dict[key] = (collect(to_append), max_transit_steps)
        end
    end

    if is_date_arrival
        time_horizon_length = maximum(key[1] for key in keys(order_dict))
    else
        time_horizon_length = if wrap_time
            maximum(key[1] for key in keys(order_dict))
        else
            maximum(key[1] + order_dict[key][2] for key in keys(order_dict))
        end
    end

    return order_dict, time_horizon_length, start_date
end

"""
$TYPEDSIGNATURES

Assemble `Bundle`s from the `order_dict` produced by [`_expand_commodities`](@ref).

Turns each entry into an `Order`, groups orders sharing `(origin_id, destination_id,
group_key)` into a bundle, aggregates each bundle's forbidden nodes and arcs from its
commodities, and rejects bundles that forbid their own origin or destination.
"""
function _build_bundles(
    order_dict,
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    group_by,
    time_horizon_length::Int,
) where {is_date_arrival,ID,I}
    first_group_key = (
        commodities[1].origin_id, commodities[1].destination_id, group_by(commodities[1])
    )
    bundle_dict = Dict{
        Tuple{String,String,eltype(first_group_key)},Vector{Order{is_date_arrival,I}}
    }()
    bundle_forbidden_dict = Dict{
        Tuple{String,String,eltype(first_group_key)},
        Tuple{Set{String},Set{Tuple{String,String}}},
    }()

    for key in keys(order_dict)
        time_step_idx, origin_id, destination_id, group_key = key
        commodities_list, min_steps = order_dict[key]
        min_steps = min(time_horizon_length, min_steps)
        # `Order`'s constructor sorts the commodities by size descending (the
        # invariant the bin-packing hot path relies on), so no sort is needed here.
        order = Order{is_date_arrival,I}(commodities_list, time_step_idx, min_steps)

        bundle_key = (origin_id, destination_id, group_key)
        if haskey(bundle_dict, bundle_key)
            push!(bundle_dict[bundle_key], order)
        else
            bundle_dict[bundle_key] = [order]
        end
    end

    # Aggregate forbidden constraints from commodities
    for commodity in commodities
        bundle_key = (commodity.origin_id, commodity.destination_id, group_by(commodity))
        if haskey(bundle_forbidden_dict, bundle_key)
            forbidden_nodes, forbidden_arcs = bundle_forbidden_dict[bundle_key]
            union!(forbidden_nodes, commodity.forbidden_node_ids)
            union!(forbidden_arcs, commodity.forbidden_arcs)
        else
            forbidden_nodes = Set{String}(commodity.forbidden_node_ids)
            forbidden_arcs = Set{Tuple{String,String}}(commodity.forbidden_arcs)
            bundle_forbidden_dict[bundle_key] = (forbidden_nodes, forbidden_arcs)
        end
    end

    group_type = fieldtype(typeof(first_group_key), 3)
    bundles = Bundle{Order{is_date_arrival,I},group_type}[]
    for key in keys(bundle_dict)
        origin_id, destination_id, group_key = key
        forbidden_nodes, forbidden_arcs = get(
            bundle_forbidden_dict, key, (Set{String}(), Set{Tuple{String,String}}())
        )

        if origin_id in forbidden_nodes
            throw(
                ArgumentError(
                    "Bundle ($origin_id → $destination_id) has forbidden node at its origin. " *
                    "Commodities cannot forbid their own origin node.",
                ),
            )
        end
        if destination_id in forbidden_nodes
            throw(
                ArgumentError(
                    "Bundle ($origin_id → $destination_id) has forbidden node at its destination. " *
                    "Commodities cannot forbid their own destination node.",
                ),
            )
        end

        bundle = Bundle(
            bundle_dict[key],
            origin_id,
            destination_id,
            forbidden_nodes,
            forbidden_arcs,
            group_key,
        )
        push!(bundles, bundle)
    end

    return bundles
end

"""
$TYPEDSIGNATURES

Check that every bundle can reach its destination from its origin in the travel-time graph
under its forbidden constraints (via [`validate_bundle_feasibility`](@ref)).

Returns `nothing` when all bundles are feasible, otherwise throws an `ArgumentError` listing
the infeasible bundles.
"""
function _validate_bundles_feasibility(ttg::TravelTimeGraph, bundles)
    infeasible_bundles = Tuple{Int,String,String}[]
    for (bundle_idx, bundle) in enumerate(bundles)
        if !validate_bundle_feasibility(ttg, bundle_idx, bundle)
            push!(infeasible_bundles, (bundle_idx, bundle.origin_id, bundle.destination_id))
        end
    end

    isempty(infeasible_bundles) && return nothing

    error_msg = "Found $(length(infeasible_bundles)) infeasible bundle(s) with no path from origin to destination"
    has_forbidden = any(
        !isempty(bundles[idx].forbidden_nodes) || !isempty(bundles[idx].forbidden_arcs) for
        (idx, _, _) in infeasible_bundles
    )
    if has_forbidden
        error_msg *= " after applying forbidden constraints"
    else
        error_msg *= " (network may be ill-defined)"
    end
    error_msg *= ":\n"
    for (idx, origin, dest) in infeasible_bundles
        error_msg *= "  • Bundle $idx: $origin → $dest\n"
    end
    if has_forbidden
        error_msg *= "Consider relaxing forbidden node/arc constraints for these bundles."
    end
    return throw(ArgumentError(error_msg))
end

"""
$TYPEDSIGNATURES

Internal builder behind the public [`Instance`](@ref) constructor. Expects `nodes` and
`arcs` already narrowed to `NetworkGraph` form (`arcs` are `(origin_id, destination_id,
NetworkArc)` tuples).

Runs the full pipeline: expand commodities into `Order`s and `Bundle`s, size the time
horizon, build the `TimeSpaceGraph` and `TravelTimeGraph`, optionally validate bundle
feasibility, and assemble the `Instance`. See [`Instance`](@ref) for the meaning of the
keyword arguments.
"""
function build_instance(
    nodes::Vector{<:NetworkNode},
    arcs::Vector{Tuple{String,String,NA}},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period;
    group_by=_default_group_by,
    wrap_time=false,
    check_bundle_feasibility=true,
    allow_multimodal::Bool=false,
) where {is_date_arrival,ID,I,NA<:NetworkArc}
    narrowed_nodes = collect_nodes(infer_node_cost_types(nodes), nodes; validate=false)
    network_graph = NetworkGraph(narrowed_nodes, arcs; allow_multimodal)
    order_dict, time_horizon_length, start_date = _expand_commodities(
        commodities, time_step, group_by, wrap_time
    )
    bundles = _build_bundles(order_dict, commodities, group_by, time_horizon_length)
    time_step_to_date = [start_date + (i - 1) * time_step for i in 1:time_horizon_length]
    time_space_graph = TimeSpaceGraph(
        network_graph, time_horizon_length; wrap_time=wrap_time
    )
    travel_time_graph = TravelTimeGraph(network_graph, bundles)
    if check_bundle_feasibility
        _validate_bundles_feasibility(travel_time_graph, bundles)
    end
    index_cache = build_index_cache(network_graph, travel_time_graph, time_space_graph)
    return Instance(;
        time_horizon_length,
        time_step,
        time_step_to_date,
        bundles,
        network_graph,
        time_space_graph,
        travel_time_graph,
        index_cache,
    )
end

"""
$TYPEDSIGNATURES

Internal builder variant that narrows `raw_arcs` into `NetworkArc`s via
[`collect_arcs`](@ref) using the explicit `arc_cost_types` (for type stability), then
delegates to the tuple-arc [`build_instance`](@ref). See [`Instance`](@ref) for the keyword
arguments.
"""
function build_instance(
    nodes::Vector{<:NetworkNode},
    raw_arcs::Vector{<:Arc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period,
    arc_cost_types::Tuple;
    group_by=_default_group_by,
    wrap_time=false,
    check_bundle_feasibility=true,
    allow_multimodal::Bool=false,
) where {is_date_arrival,ID,I}
    arcs = collect_arcs(arc_cost_types, raw_arcs, time_step)
    return build_instance(
        nodes,
        arcs,
        commodities,
        time_step;
        group_by,
        wrap_time,
        check_bundle_feasibility,
        allow_multimodal,
    )
end

"""
    Instance(
        nodes::Vector{<:NetworkNode},
        arcs::Vector{<:Arc},
        commodities::Vector{Commodity{is_date_arrival,ID,I}},
        time_step::Period;
        group_by=_default_group_by,
        wrap_time=false,
        check_bundle_feasibility=true,
        allow_multimodal=false,
    ) where {is_date_arrival,ID,I}

Construct an `Instance` from high-level `Arc` inputs by automatically inferring cost
function types. This is the main entry point for building a problem instance.

# Arguments
- `nodes::Vector{<:NetworkNode}`: List of nodes in the spatial network.
- `arcs::Vector{<:Arc}`: Arcs in the spatial network. `Instance` infers cost types and
narrows the vector internally via [`collect_arcs`](@ref) before building the `NetworkGraph`.
- `commodities::Vector{Commodity}`: User-facing commodity specifications.
- `time_step::Period`: The discrete time step size (e.g., `Hour(1)`, `Day(1)`).

Keywords:
- `group_by` (default: `_default_group_by`): Optional function to group commodities into
`Order`s (default: no additional grouping).
- `wrap_time` (default: false): whether the time horizon should wrap (cyclic)
- `check_bundle_feasibility` (default: true): whether to validate that bundles have feasible
paths after applying forbidden constraints
- `allow_multimodal` (default: false): opt-in switch for multi-modal legs. When false,
duplicate `(origin_id, destination_id)` arcs raise an `ArgumentError`. When true,
duplicates are auto-promoted to a `MultiModalArc`.

# Discretization and Normalization
1. **Start Date**: The time horizon starts at the earliest release date
(for departure-based) or the earliest possible start (for arrival-based).
2. **Time Steps**: Dates and periods are converted to discrete steps using `period_steps`.
3. **Consolidation**: Commodities with the same origin, destination, and delivery step are
grouped into `Order`s. Orders with the same origin and destination are grouped into
`Bundle`s for routing.
4. **Graphs**: Both `TimeSpaceGraph` and `TravelTimeGraph` are constructed.
"""
function Instance(
    nodes::Vector{<:NetworkNode},
    raw_arcs::Vector{<:Arc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
    time_step::Period;
    group_by=_default_group_by,
    wrap_time=false,
    check_bundle_feasibility=true,
    allow_multimodal::Bool=false,
) where {is_date_arrival,ID,I}
    # Infer cost types from the arcs
    cost_types = infer_cost_types(raw_arcs)
    # Delegate to the type-stable version
    return build_instance(
        nodes,
        raw_arcs,
        commodities,
        time_step,
        cost_types;
        group_by,
        wrap_time,
        check_bundle_feasibility,
        allow_multimodal,
    )
end
