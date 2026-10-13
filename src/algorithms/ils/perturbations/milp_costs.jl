"""
$TYPEDSIGNATURES

Linear cost of putting `order` on an arc with cost function `c` in the arc-flow MILP.
It is the lower bound [`lower_bound_incremental_cost_with_order`](@ref) against an empty
arc, which is exact for linear costs and the fractional part for custom costs.
The bins of a [`BinPackingArcCost`](@ref) are not part of it, they are counted by the
integer bin variables of the model (see [`_bin_packing_cost_of`](@ref)).
"""
function _milp_linear_cost(c::AbstractArcCostFunction, order::Order)
    return lower_bound_incremental_cost_with_order(c, nothing, order)
end
_milp_linear_cost(::BinPackingArcCost, ::Order) = 0.0
function _milp_linear_cost(c::SumArcCost, order::Order)
    return sum(_milp_linear_cost(t, order) for t in c.terms)
end

"""
$TYPEDSIGNATURES

Empty JuMP model for a perturbation MILP: silent, with a relative gap and a single thread
when the solver supports the attribute. The caller sets the time limit before the solve.
"""
function _milp_model(optimizer, mip_gap::Real)
    model = JuMP.Model(optimizer)
    JuMP.set_silent(model)
    JuMP.set_attribute(model, JuMP.MOI.RelativeGapTolerance(), mip_gap)
    try
        JuMP.set_attribute(model, JuMP.MOI.NumberOfThreads(), 1)
    catch err
        err isa JuMP.MOI.UnsupportedAttribute || rethrow()
    end
    return model
end

"""
$TYPEDSIGNATURES

Copy the cached `model` to its optimizer now. JuMP otherwise does it inside `optimize!`,
where it escapes the time limit, which is set from the time left after this call.
"""
function _milp_attach!(model::JuMP.Model)
    JuMP.MOI.Utilities.attach_optimizer(model)
    return nothing
end

"""
$TYPEDSIGNATURES

Linear objective coefficient of routing `bundle` over the non-shortcut TTG edge `u -> v`:
the slope-scaled linear arc cost plus the head node cost, summed over the orders (see
[`_milp_linear_cost`](@ref)). The bins of the edge are not part of it.
"""
function _milp_arc_coefficient(instance::Instance, bundle::Bundle, u::Int, v::Int)
    cache = instance.index_cache
    arc = ttg_edge_arc(cache, u, v)
    # A virtual arc carries no cost and its head is a hub, which must not be charged.
    _is_virtual(arc) && return 0.0
    scaling = get(instance.travel_time_graph.cost_scaling, ttg_edge_key(cache, u, v), 1.0)
    node_cost = cache.spatial_code_to_node_cost[cache.ttg_code_to_spatial_code[v]]
    coefficient = 0.0
    for order in bundle.orders
        coefficient += scaling * _milp_linear_cost(arc.cost, order)
        coefficient += _node_lower_bound_incremental_cost(
            node_cost, nothing, order.commodities, order.total_size
        )
    end
    return coefficient
end

"""
$TYPEDSIGNATURES

Add the integer bin variable of the time-space edge `e` (carried by `arc`) to `tau` if it
has a bin cost and none yet, and its slope-scaled cost to `objective`.
"""
function _milp_add_bins!(model, tau, objective, e::Tuple{Int,Int}, arc, scaling::Real)
    bin = _bin_packing_cost_of(arc.cost)
    (isnothing(bin) || haskey(tau, e)) && return nothing
    tau[e] = @variable(model, lower_bound = 0, integer = true)
    JuMP.add_to_expression!(objective, scaling * bin.cost_per_bin, tau[e])
    return nothing
end

"""
$TYPEDSIGNATURES

Add the packing and capacity constraints of every time-space edge in `loads` (the variable
part of its load, on top of the constant `background[e]`) with the bins `tau[e]` and the arc
`edge_arc[e]`.
"""
function _milp_add_packing!(model, loads, tau, edge_arc, background)
    for (e, expr) in loads
        arc = edge_arc[e]
        bin = _bin_packing_cost_of(arc.cost)
        isnothing(bin) ||
            @constraint(model, expr - bin.bin_capacity * tau[e] <= -background[e])
        arc.capacity == typemax(Int) ||
            @constraint(model, expr <= arc.capacity - background[e])
    end
    return nothing
end

# Current total size on the time-space edge `e`.
function _milp_current_load(sol::SolutionState, e::Tuple{Int,Int})
    return haskey(sol.assignments, e) ? total_size_of(sol.assignments[e]) : 0.0
end

# Start values of the bins: the number needed by the current load of each edge.
function _milp_start_bins!(tau, sol::SolutionState, instance::Instance)
    for (e, var) in tau
        bin = _bin_packing_cost_of(tsg_edge_arc(instance.index_cache, e[1], e[2]).cost)
        current = _milp_current_load(sol, e)
        JuMP.set_start_value(var, ceil(max(0.0, current / bin.bin_capacity - 1e-9)))
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Structured log fields of a MILP `model` after its solve: size, build and solve times,
solver status, objective and relative gap (`missing` without a solution).
"""
function _milp_fields(model::JuMP.Model, build_time::Real, solve_time::Real)
    solved = JuMP.has_values(model)
    gap = try
        solved ? JuMP.relative_gap(model) : missing
    catch
        missing
    end
    return (;
        n_variables=JuMP.num_variables(model),
        n_constraints=JuMP.num_constraints(model; count_variable_in_set_constraints=false),
        build_time,
        solve_time,
        termination=JuMP.termination_status(model),
        primal=JuMP.primal_status(model),
        objective=solved ? JuMP.objective_value(model) : missing,
        gap,
    )
end
