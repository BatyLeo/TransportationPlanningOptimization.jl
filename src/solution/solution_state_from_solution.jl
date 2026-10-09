"""
$TYPEDSIGNATURES

Build the [`SolutionState`](@ref) of the plan `solution` on `instance`, the reverse of `Solution(solution_state, instance)`.
The routes are the source of truth and give the paths and the input arcs (modes) of every commodity.
The `arc_flows` are ignored, and the capacity reserved for commodities dropped by an extraction is not rebuilt.
A leg on an input arc with no arc in the instance (a loop, a skipped `transit=false` arc or an arc dropped by an extraction) is rejected.
Commodities not routed by the instance (mapped to `(0, 0)`, such as the ones with their origin equal to their destination) must have an empty route.
Every slot of every edge is repacked by first-fit decreasing, so bins and costs only equal those of the original state for linear costs (up to floating point summation order).
Capacity is not checked, run [`is_feasible`](@ref) on the result.
Several legs on the same arc at the same position are merged, and the solution-level round trip `Solution(SolutionState(solution, instance), instance) == solution` only holds for solutions produced by `Solution(solution_state, instance)`.
Other plans come back normalized, with the legs of one leg position merged and in slot order and identical copies attributed by count.

An `ArgumentError` is thrown for the first rule a route breaks, checked in this order:
- a wrong number of routes, a route for a dropped commodity or an empty route for a kept one,
- an arc index out of range or absent from `instance`, a non-positive quantity or a leg quantity above the commodity quantity, a commodity size above the bin capacity of the arc, dates off the time grid or a transit time different from the arc one,
- copies not adding up to the commodity quantity (also when they are split across legs between two nodes that differ in dates or are not consecutive),
- a route that does not start at the commodity origin, legs that are not connected, wait anywhere but before the first leg (arrival-date instances) or after the last leg (departure-date instances), or overlap,
- a route that does not end at the commodity destination,
- a route not pinned to the order date, which is its arrival in arrival-date mode and its departure in departure-date mode,
- a route longer than the maximum delivery time of its commodity group,
- a route that leaves the time horizon of the instance when `wrap_time` is off, or passes through an origin or destination node that routes cannot cross at that date,
- a route through a forbidden node or arc, or not elementary,
- commodities of one group (same origin, destination and group key) that do not follow the same path (same nodes and transit times) at the same offsets from their order date.
"""
function SolutionState(
    solution::Solution, instance::Instance{<:Bundle{<:Order{IDA,I}}}
) where {IDA,I}
    C = LightCommodity{I}
    cache = instance.index_cache
    input_commodities = instance.input.commodities
    length(solution.routes) == length(input_commodities) || throw(
        ArgumentError(
            "the solution has $(length(solution.routes)) routes " *
            "for $(length(input_commodities)) input commodities",
        ),
    )
    for (k, (b, _)) in enumerate(instance.commodity_to_order)
        b == 0 &&
            !isempty(solution.routes[k]) &&
            throw(
                ArgumentError(
                    "route of input commodity $k: the commodity is dropped by the instance " *
                    "and must have an empty route",
                ),
            )
    end
    locations = _arc_locations(instance)
    by_order = _commodities_by_order(instance)
    paths = [Int[] for _ in instance.bundles]
    loads = Dict{Tuple{Int,Int},Vector{Vector{C}}}()
    for (b, bundle) in enumerate(instance.bundles)
        reference = by_order[b][1][1]
        for (o, order) in enumerate(bundle.orders), k in by_order[b][o]
            positions = _route_positions(
                instance, locations, b, k, order, solution.routes[k]
            )
            codes = _position_codes(instance, b, order, k, positions)
            if k == reference
                paths[b] = codes
                _check_bundle_path(instance, b, k, codes)
            elseif codes != paths[b]
                throw(
                    ArgumentError(
                        "input commodities $reference and $k are grouped together " *
                        "(same origin $(bundle.origin_id), destination " *
                        "$(bundle.destination_id) and group key) but do not follow the " *
                        "same path (same nodes and transit times) at the same offsets " *
                        "from their order date",
                    ),
                )
            end
            _place_copies!(loads, instance, order, input_commodities[k], positions, codes)
        end
    end
    assignments = Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}()
    for (edge, edge_loads) in loads
        arc = tsg_edge_arc(cache, edge...)
        sv = cache.tsg_code_to_spatial_code[edge[2]]
        for load in edge_loads
            sizehint!(load, length(load); shrink=true)
        end
        assignments[edge] = _filled_assignment(
            arc, edge_loads, cache.spatial_code_to_node_cost[sv]
        )
    end
    return SolutionState{C}(paths, assignments)
end

# Input arc `index` as `(origin, destination, transit, slot, bin_capacity)`: spatial codes of its ends, transit steps,
# slot in the `modes` of its per-transit-time sub-arc and bin capacity (infinite without bin packing). All zeros (and an infinite bin capacity) if the arc has no arc in the instance (loop, skipped `transit=false` arc or dropped by an extraction).
function _arc_locations(instance::Instance)
    ng = instance.network_graph.graph
    locations = fill(
        (; origin=0, destination=0, transit=0, slot=0, bin_capacity=Inf),
        length(instance.input.arcs),
    )
    for (u, v) in MetaGraphsNext.edge_labels(ng)
        origin, destination = MetaGraphsNext.code_for(ng, u), MetaGraphsNext.code_for(ng, v)
        for (transit, arc) in _mode_groups(ng[u, v])
            for slot in 1:_slot_count(arc)
                index = input_arc_index(arc, slot)
                iszero(index) && continue
                iszero(locations[index].origin) ||
                    error("input arc $index is used by several arcs of the network graph")
                bp = _bin_packing_cost_of((arc isa NetworkArc ? arc : arc.modes[slot]).cost)
                bin_capacity = isnothing(bp) ? Inf : Float64(bp.bin_capacity)
                locations[index] = (; origin, destination, transit, slot, bin_capacity)
            end
        end
    end
    return locations
end

# Where waiting is possible, for the message of an intermediate wait.
_waiting_rule(::Order{true}) = "before the first leg (arrival-date instance)"
_waiting_rule(::Order{false}) = "after the last leg (departure-date instance)"

# Leg index, step, and messages when the step is after or before the order date, for the end of the route
# that is pinned to the order date.
function _order_end(order::Order{true}, positions)
    return (
        positions[end].leg,
        positions[end].arrival,
        "arrives after the order date, which is a deadline violation",
        "arrives before the order date, waiting at the destination is not representable",
    )
end
function _order_end(order::Order{false}, positions)
    return (
        positions[1].leg,
        positions[1].departure,
        "departs after the order date, waiting at the origin is not representable",
        "departs before the order date, which is a release violation",
    )
end

# A group of legs sharing arc location and dates, carrying `slots` as `slot => copies`.
struct _Position
    leg::Int
    origin::Int
    destination::Int
    departure::Int
    arrival::Int
    slots::Vector{Pair{Int,Int}}
end

# Validate the route `legs` of input commodity `k` of bundle `b` and group its legs into path positions.
function _route_positions(instance::Instance, locations, b::Int, k::Int, order::Order, legs)
    ng = instance.network_graph.graph
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    start, Δ = instance.time_step_to_date[1], instance.time_step
    commodity = instance.input.commodities[k]
    name(s) = MetaGraphsNext.label_for(ng, s)
    date(t) = _step_date(start, Δ, t)
    fail(i, message) = throw(ArgumentError("route of input commodity $k, leg $i: $message"))
    isempty(legs) && throw(ArgumentError("route of input commodity $k: the route is empty"))
    positions = _Position[]
    for (i, leg) in enumerate(legs)
        1 <= leg.arc <= length(locations) ||
            fail(i, "arc index $(leg.arc) is out of range 1:$(length(locations))")
        location = locations[leg.arc]
        iszero(location.origin) && fail(
            i,
            "input arc $(leg.arc) has no arc in the instance (ignored at construction as a loop or a skipped transit=false arc, or dropped by an extraction)",
        )
        leg.quantity >= 1 || fail(i, "quantity $(leg.quantity) is not positive")
        leg.quantity <= commodity.quantity || fail(
            i,
            "quantity $(leg.quantity) exceeds the commodity quantity $(commodity.quantity)",
        )
        commodity.size <= location.bin_capacity + EPS || fail(
            i,
            "size $(commodity.size) exceeds the bin capacity $(location.bin_capacity) " *
            "of input arc $(leg.arc)",
        )
        departure = _date_step(leg.departure, start, Δ)
        arrival = _date_step(leg.arrival, start, Δ)
        (isnothing(departure) || isnothing(arrival)) && fail(
            i,
            "date $(isnothing(departure) ? leg.departure : leg.arrival) is not on the " *
            "time grid (start $start, step $Δ)",
        )
        arrival - departure == location.transit || fail(
            i,
            "arrival is $(arrival - departure) steps after departure, " *
            "input arc $(leg.arc) takes $(location.transit)",
        )
        if !isempty(positions) &&
            (positions[end].origin, positions[end].destination) ==
            (location.origin, location.destination) &&
            (positions[end].departure, positions[end].arrival) == (departure, arrival)
            push!(positions[end].slots, location.slot => leg.quantity)
        else
            push!(
                positions,
                _Position(
                    i,
                    location.origin,
                    location.destination,
                    departure,
                    arrival,
                    [location.slot => leg.quantity],
                ),
            )
        end
    end
    for (p, position) in enumerate(positions)
        copies = sum(last, position.slots)
        if copies != commodity.quantity
            split = any(
                q ->
                    q !== position &&
                    (q.origin, q.destination) == (position.origin, position.destination),
                positions,
            )
            fail(
                position.leg,
                if split
                    "copies of the commodity are split across legs from " *
                    "$(name(position.origin)) to $(name(position.destination)) that differ " *
                    "in dates or are not consecutive, all copies must travel together " *
                    "between two nodes"
                else
                    "the legs of this position carry a total quantity of $copies, " *
                    "the commodity has quantity $(commodity.quantity)"
                end,
            )
        end
        if p == 1
            position.origin == cache.ttg_code_to_spatial_code[ttg.origin_codes[b]] || fail(
                position.leg,
                "the route starts at $(name(position.origin)), " *
                "not at the commodity origin $(instance.bundles[b].origin_id)",
            )
            continue
        end
        previous = positions[p - 1]
        previous.destination == position.origin || fail(
            position.leg,
            "the leg starts at $(name(position.origin)) but the previous leg " *
            "ends at $(name(previous.destination))",
        )
        position.departure > previous.arrival && fail(
            position.leg,
            "waits at $(name(position.origin)) from $(date(previous.arrival)) to " *
            "$(date(position.departure)), waiting is only possible " *
            _waiting_rule(order),
        )
        position.departure < previous.arrival && fail(
            position.leg,
            "the leg departs at $(date(position.departure)) before the previous leg " *
            "arrives at $(date(previous.arrival)), the legs overlap",
        )
    end
    last_position = positions[end]
    last_position.destination == cache.ttg_code_to_spatial_code[ttg.destination_codes[b]] ||
        fail(
            last_position.leg,
            "the route ends at $(name(last_position.destination)), " *
            "not at the commodity destination $(instance.bundles[b].destination_id)",
        )
    return positions
end

# Travel-time nodes of the path of `positions`, checking the end date against the order date,
# the duration against the group budget, the time horizon and the crossable nodes.
function _position_codes(instance::Instance, b::Int, order::Order, k::Int, positions)
    cache = instance.index_cache
    start, Δ = instance.time_step_to_date[1], instance.time_step
    ng = instance.network_graph.graph
    leg, step, after, before = _order_end(order, positions)
    step == order.time_step || throw(
        ArgumentError(
            "route of input commodity $k, leg $leg: the route " *
            "$(step > order.time_step ? after : before) " *
            "(order date $(_step_date(start, Δ, order.time_step)))",
        ),
    )
    # The other end is pinned to the order date, so the duration is the budget used at the free end.
    bundle = instance.bundles[b]
    positions[end].arrival - positions[1].departure >
    maximum(o.max_transit_steps for o in bundle.orders) && throw(
        ArgumentError(
            "route of input commodity $k: the route is longer than the maximum delivery " *
            "time of its commodity group ($(bundle.origin_id) -> $(bundle.destination_id))",
        ),
    )
    codes = Int[]
    function push_node!(leg, node, t)
        instance.time_space_graph.wrap_time ||
            1 <= t <= instance.time_horizon_length ||
            throw(
                ArgumentError(
                    "route of input commodity $k, leg $leg: node " *
                    "$(MetaGraphsNext.label_for(ng, node)) at $(_step_date(start, Δ, t)) is " *
                    "outside the time horizon $(first(instance.time_step_to_date)) to " *
                    "$(last(instance.time_step_to_date)) of the instance",
                ),
            )
        code = ttg_code_at(cache, node, _order_tau(order, t))
        iszero(code) && throw(
            ArgumentError(
                "route of input commodity $k, leg $leg: node " *
                "$(MetaGraphsNext.label_for(ng, node)) at $(_step_date(start, Δ, t)) " *
                "is not allowed, the route passes through an origin or destination node " *
                "that routes cannot cross at this date",
            ),
        )
        return push!(codes, code)
    end
    push_node!(positions[1].leg, positions[1].origin, positions[1].departure)
    for position in positions
        push_node!(position.leg, position.destination, position.arrival)
    end
    return codes
end

# Check the path of the reference commodity `k` of bundle `b` with the forbidden node,
# forbidden arc and elementary rules of `is_feasible` (the others hold by construction of the codes).
function _check_bundle_path(instance::Instance, b::Int, k::Int, path::Vector{Int})
    ttg = instance.travel_time_graph
    bundle = instance.bundles[b]
    spatial = instance.index_cache.ttg_code_to_spatial_code
    ids = [MetaGraphsNext.label_for(ttg.graph, code)[1] for code in path]
    fail(message) = throw(ArgumentError("route of input commodity $k: $message"))
    for id in ids[2:(end - 1)]
        id in bundle.forbidden_nodes && fail("the route uses forbidden node $id")
    end
    for arc in zip(ids[1:(end - 1)], ids[2:end])
        arc in bundle.forbidden_arcs && fail("the route uses forbidden arc $arc")
    end
    is_elementary_path(path, spatial) ||
        fail("the route is not elementary, it revisits a node of $ids")
    return nothing
end

# Append the copies of `commodity` to the slot loads of the time-space edges of its path.
function _place_copies!(
    loads::Dict{Tuple{Int,Int},Vector{Vector{C}}},
    instance::Instance,
    order::Order,
    commodity,
    positions,
    codes,
) where {C<:LightCommodity}
    cache = instance.index_cache
    light = _light_commodity(commodity)
    for (p, position) in enumerate(positions)
        u, v = codes[p], codes[p + 1]
        arc = ttg_edge_arc(cache, u, v)
        edge = (
            project_to_time_space_graph(u, order, instance),
            project_to_time_space_graph(v, order, instance),
        )
        edge_loads = get!(() -> [C[] for _ in 1:_slot_count(arc)], loads, edge)
        for (slot, copies) in position.slots
            append!(edge_loads[slot], Iterators.repeated(light, copies))
        end
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Build the full [`Solution`](@ref) of the `routes` on `instance`, with `arc_flows` and [`cost`](@ref) rebuilt from the routes.
The routes are the source of truth and are validated like in `SolutionState(solution, instance)`, which this function calls before converting back.
The bins are repacked deterministically, so the cost only equals that of the original plan for linear costs (up to floating point summation order).
Throws an `ArgumentError` if the routes are not a valid plan, see [`SolutionState`](@ref).
Capacity is not checked, run [`is_feasible`](@ref) on the result.
"""
function Solution(routes::Vector{Vector{Leg}}, instance::Instance)
    return Solution(SolutionState(Solution(routes, ArcFlow[]), instance), instance)
end
