"""
$TYPEDEF

One leg of an input commodity: input arc index, dates and number of copies carried.

# Fields
$TYPEDFIELDS
"""
@kwdef struct Leg
    "index of the input arc"
    arc::Int
    "departure date"
    departure::Dates.DateTime
    "arrival date"
    arrival::Dates.DateTime
    "number of copies carried on this leg"
    quantity::Int
end

"""
$TYPEDEF

One row of load on an input arc: dates, volume, bins and costs.
The node cost of a multi-modal edge is charged once, on its first non-empty mode row.

# Fields
$TYPEDFIELDS
"""
@kwdef struct ArcFlow
    "index of the input arc"
    arc::Int
    "departure date"
    departure::Dates.DateTime
    "arrival date"
    arrival::Dates.DateTime
    "total volume carried"
    volume::Float64
    "number of bins used"
    n_bins::Int
    "arc cost of this row"
    arc_cost::Float64
    "node cost of this row"
    node_cost::Float64
end

"""
$TYPEDEF

The solution expressed on the user input of an [`Instance`](@ref), built from a
[`SolutionState`](@ref) by `Solution(solution_state, instance)`.
Arcs and commodities are identified by their index in the input vectors, and dates are `DateTime`s at the start of a time step.

- `routes[k]` lists the legs of input commodity `k` in travel order.
  An order split across the modes of a multi-modal arc gives one leg per mode, each with the copies it carries.
  Waiting is the gap before the first leg or after the last one.
- `arc_flows` gives the load and costs per input arc and departure, and sums to `cost(solution_state)` (up to floating point summation order).
  With `wrap_time`, its departures are cyclic while route dates are not.

See [Reading a solution on the input network](@ref solution_guide) for the date
conventions, how to match routes with flows, and how identical copies are attributed.

# Fields
$TYPEDFIELDS
"""
struct Solution
    "`routes[k]` is the list of legs of input commodity `k`"
    routes::Vector{Vector{Leg}}
    "load per input arc and departure date, sorted by `(arc, departure)`"
    arc_flows::Vector{ArcFlow}
end

function Base.show(io::IO, solution::Solution)
    n_legs = sum(length, solution.routes; init=0)
    return print(
        io,
        "Solution(commodities=$(length(solution.routes)), legs=$(n_legs), ",
        "flows=$(length(solution.arc_flows)), cost=$(cost(solution)))",
    )
end

"""
$TYPEDSIGNATURES

Total arc cost of `solution`, the sum of `arc_cost` over its `arc_flows`.
"""
function total_arc_cost(solution::Solution)
    return sum(f -> f.arc_cost, solution.arc_flows; init=0.0)
end

"""
$TYPEDSIGNATURES

Total node cost of `solution`, the sum of `node_cost` over its `arc_flows`.
"""
function total_node_cost(solution::Solution)
    return sum(f -> f.node_cost, solution.arc_flows; init=0.0)
end

"""
$TYPEDSIGNATURES

Total cost of `solution`, the sum of `arc_cost + node_cost` over its `arc_flows`.
The costs are read from `arc_flows`, so after editing `routes` refresh them with `Solution(solution.routes, instance)`.
"""
function cost(solution::Solution)
    return sum(f -> f.arc_cost + f.node_cost, solution.arc_flows; init=0.0)
end

"""
$TYPEDSIGNATURES

Check that `solution` is feasible on `instance`.
The `arc_flows` are ignored: the plan is rebuilt from the routes by `SolutionState(solution, instance)`, with bins repacked by first-fit decreasing.
Returns `false` (with a warning if `verbose`) when the routes cannot be represented on `instance`, otherwise the result of [`is_feasible`](@ref) on the rebuilt [`SolutionState`](@ref).
On a sub-instance the reserved load of dropped bundles is not rebuilt, so capacity is checked without it.
"""
function is_feasible(solution::Solution, instance::Instance; verbose::Bool=false, tol=EPS)
    solution_state = try
        SolutionState(solution, instance)
    catch err
        err isa ArgumentError || rethrow()
        verbose && @warn "Solution cannot be represented on the instance: $(err.msg)"
        return false
    end
    return is_feasible(solution_state, instance; verbose, tol)
end

"""
$TYPEDSIGNATURES

Project `solution_state` onto the input of `instance`, see [`Solution`](@ref).
The result is only meaningful if `solution_state` passes [`is_feasible`](@ref).
Some mismatches raise an `ArgumentError`, such as missing copies or a wrong number of slots
on a multi-modal edge.
"""
function Solution(solution_state::SolutionState, instance::Instance)
    start = instance.time_step_to_date[1]
    Δ = instance.time_step
    return Solution(
        _routes(solution_state, instance, start, Δ),
        _arc_flows(solution_state, instance, start, Δ),
    )
end

# Date at the start of the (possibly unwrapped) time step `t`.
_step_date(start, Δ, t::Int) = start + (t - 1) * Δ

# Exact inverse of `_step_date`, `nothing` if `date` is not the start of a time step.
function _date_step(date, start, Δ)
    n = period_steps(date - start, Δ)
    return start + n * Δ == date ? n + 1 : nothing
end

# Unwrapped time step of a travel-time node with budget `τ` for `order`.
_order_step(order::Order{true}, τ::Int) = order.time_step - τ
_order_step(order::Order{false}, τ::Int) = order.time_step + τ

# Travel-time budget of the unwrapped time step `t` for `order`, inverse of `_order_step`.
_order_tau(order::Order{true}, t::Int) = order.time_step - t
_order_tau(order::Order{false}, t::Int) = t - order.time_step

# Input commodity indices of each order: `by_order[b][o]` for order `o` of bundle `b`.
function _commodities_by_order(instance::Instance)
    by_order = [[Int[] for _ in bundle.orders] for bundle in instance.bundles]
    for (k, (b, o)) in enumerate(instance.commodity_to_order)
        b == 0 || push!(by_order[b][o], k)
    end
    return by_order
end

function _routes(sol::SolutionState{C}, instance::Instance, start, Δ) where {C}
    cache = instance.index_cache
    input_commodities = instance.input.commodities
    routes = [Leg[] for _ in input_commodities]
    by_order = _commodities_by_order(instance)
    # Per multi-modal edge, the copies left to attribute in each slot. Orders, bundles and
    # reservations on the same time-space edge draw from the same counts.
    edge_counts = Dict{Tuple{Int,Int},Vector{Dict{C,Int}}}()
    for (edge, a) in sol.assignments
        a isa MultiAssignment || continue
        edge_counts[edge] = map(a.per_mode) do slot
            counts = Dict{C,Int}()
            for c in slot.commodities
                counts[c] = get(counts, c, 0) + 1
            end
            return counts
        end
    end
    for (b, (bundle, path)) in enumerate(zip(instance.bundles, sol.bundle_paths))
        stripped = copy(path)
        _remove_shortcuts_from_path!(stripped, instance.travel_time_graph)
        for p in 1:(length(stripped) - 1)
            u, v = stripped[p], stripped[p + 1]
            arc = ttg_edge_arc(cache, u, v)
            isnothing(arc) && throw(ArgumentError("TTG edge ($u, $v) has no network arc"))
            τ_u, τ_v = cache.ttg_code_to_tau[u], cache.ttg_code_to_tau[v]
            for (o, order) in enumerate(bundle.orders)
                departure = _step_date(start, Δ, _order_step(order, τ_u))
                arrival = _step_date(start, Δ, _order_step(order, τ_v))
                edge = (
                    project_to_time_space_graph(u, order, instance),
                    project_to_time_space_graph(v, order, instance),
                )
                counts = get(edge_counts, edge, Dict{C,Int}[])
                _add_legs!(
                    routes,
                    arc,
                    input_commodities,
                    by_order[b][o],
                    departure,
                    arrival,
                    counts,
                )
            end
        end
    end
    return routes
end

# Single-mode edge: every commodity of the order travels on the arc with its full quantity.
function _add_legs!(routes, arc::NetworkArc, commodities, ks, departure, arrival, _)
    iszero(arc.input_index) && return nothing
    for k in ks
        push!(routes[k], Leg(arc.input_index, departure, arrival, commodities[k].quantity))
    end
    return nothing
end

# Multi-modal edge: the copies of each commodity are taken from the slots in slot order.
function _add_legs!(routes, arc::MultiModalArc, commodities, ks, departure, arrival, counts)
    isempty(counts) ||
        length(counts) == length(arc.modes) ||
        throw(
            ArgumentError(
                "assignment has $(length(counts)) slots for $(length(arc.modes)) modes, " *
                "check the solution with `is_feasible`",
            ),
        )
    for k in ks
        c = commodities[k]
        light = _light_commodity(c)
        remaining = c.quantity
        for (slot, slot_count) in enumerate(counts)
            taken = min(remaining, get(slot_count, light, 0))
            taken > 0 || continue
            slot_count[light] -= taken
            remaining -= taken
            index = input_arc_index(arc, slot)
            iszero(index) || push!(routes[k], Leg(index, departure, arrival, taken))
        end
        remaining > 0 && throw(
            ArgumentError(
                "$remaining copies of input commodity $k are missing from the " *
                "assignment of a multi-modal edge, check the solution with `is_feasible`",
            ),
        )
    end
    return nothing
end

function _arc_flows(sol::SolutionState, instance::Instance, start, Δ)
    cache = instance.index_cache
    rows = ArcFlow[]
    for ((u, v), assignment) in sol.assignments
        arc = tsg_edge_arc(cache, u, v)
        isnothing(arc) &&
            throw(ArgumentError("assignment on a time-space edge with no network arc"))
        t = cache.tsg_code_to_time[u]
        _arc_flow_rows!(rows, assignment, arc, start, Δ, t)
    end
    sort!(rows; by=r -> (r.arc, r.departure))
    return rows
end

# Number of bins of `slot`: its bins always hold exactly its commodities, so this matches the arc cost.
function _n_bins(slot::SingleAssignment, cost::AbstractArcCostFunction)
    bp = _bin_packing_cost_of(cost)
    isnothing(bp) && return 0
    return length(slot.bins)
end

function _flow_row(slot::SingleAssignment, mode::NetworkArc, start, Δ, t, node_cost)
    return ArcFlow(;
        arc=mode.input_index,
        departure=_step_date(start, Δ, t),
        arrival=_step_date(start, Δ, t + mode.travel_time_steps),
        volume=slot.total_size,
        n_bins=_n_bins(slot, mode.cost),
        arc_cost=slot.arc_cost,
        node_cost=node_cost,
    )
end

function _arc_flow_rows!(rows, a::SingleAssignment, arc::NetworkArc, start, Δ, t)
    isempty(a.commodities) && return nothing
    push!(rows, _flow_row(a, arc, start, Δ, t, a.node_cost))
    return nothing
end

function _arc_flow_rows!(rows, a::MultiAssignment, arc::MultiModalArc, start, Δ, t)
    length(a.per_mode) == length(arc.modes) || throw(
        ArgumentError(
            "assignment has $(length(a.per_mode)) slots for $(length(arc.modes)) modes, " *
            "check the solution with `is_feasible`",
        ),
    )
    node_cost = a.node_cost
    for (slot, mode) in zip(a.per_mode, arc.modes)
        isempty(slot.commodities) && continue
        push!(rows, _flow_row(slot, mode, start, Δ, t, node_cost))
        node_cost = 0.0
    end
    return nothing
end

function _arc_flow_rows!(rows, ::AbstractArcAssignment, ::AbstractNetworkArc, args...)
    return throw(
        ArgumentError(
            "assignment type does not match its edge arc, check the solution with `is_feasible`",
        ),
    )
end
