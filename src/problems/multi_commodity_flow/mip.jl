"""
$TYPEDSIGNATURES

Solve the exact MIP for `data` with JuMP.

Returns a `NamedTuple` with fields `node_paths`, `objective_bound`, `termination_status`
and `solve_time`.
`node_paths[k]` is the node path of commodity `k`, or `node_paths` is `nothing` if no
incumbent was found.
"""
function _solve_mip(
    data::_MCFData;
    optimizer=HiGHS.Optimizer,
    time_limit::Union{Nothing,Real}=nothing,
    silent::Bool=true,
)
    n_arcs = length(data.tails)
    n_commodities = length(data.origins)
    n_nodes = data.n_nodes

    out_arcs = [Int[] for _ in 1:n_nodes]
    in_arcs = [Int[] for _ in 1:n_nodes]
    for a in 1:n_arcs
        push!(out_arcs[data.tails[a]], a)
        push!(in_arcs[data.heads[a]], a)
    end

    model = Model(optimizer)
    silent && set_silent(model)
    !isnothing(time_limit) && set_time_limit_sec(model, Float64(time_limit))

    @variable(model, x[1:n_arcs, 1:n_commodities], Bin)

    @constraint(
        model,
        flow_conservation[k in 1:n_commodities, v in 1:n_nodes],
        sum(x[a, k] for a in out_arcs[v]) - sum(x[a, k] for a in in_arcs[v]) ==
            (v == data.origins[k]) - (v == data.destinations[k])
    )
    @constraint(
        model,
        out_degree[k in 1:n_commodities, v in 1:n_nodes],
        sum(x[a, k] for a in out_arcs[v]) <= 1
    )
    for k in 1:n_commodities, a in out_arcs[data.destinations[k]]
        fix(x[a, k], 0; force=true)
    end

    routing_cost = @expression(
        model,
        sum(
            data.var_costs[a] * data.demands[k] * x[a, k] for
            a in 1:n_arcs, k in 1:n_commodities
        )
    )

    if data.network_design
        @variable(model, y[1:n_arcs], Bin)
        @constraint(
            model,
            capacity[a in 1:n_arcs],
            sum(data.demands[k] * x[a, k] for k in 1:n_commodities) <=
                data.capacities[a] * y[a]
        )
        @constraint(model, linking[a in 1:n_arcs, k in 1:n_commodities], x[a, k] <= y[a])
        @objective(
            model, Min, routing_cost + sum(data.fixed_costs[a] * y[a] for a in 1:n_arcs)
        )
    else
        @constraint(
            model,
            capacity[a in 1:n_arcs],
            sum(data.demands[k] * x[a, k] for k in 1:n_commodities) <= data.capacities[a]
        )
        @objective(model, Min, routing_cost)
    end

    optimize!(model)

    status = termination_status(model)
    obj_bound = if status in (INFEASIBLE, INFEASIBLE_OR_UNBOUNDED)
        Inf
    else
        objective_bound(model)::Float64
    end

    node_paths = if primal_status(model) == FEASIBLE_POINT
        map(1:n_commodities) do k
            path = [data.origins[k]]
            v = data.origins[k]
            while v != data.destinations[k]
                a = only(a for a in out_arcs[v] if value(x[a, k]) > 0.5)
                v = data.heads[a]
                push!(path, v)
            end
            return path
        end
    else
        nothing
    end

    return (;
        node_paths,
        objective_bound=obj_bound,
        termination_status=status,
        solve_time=solve_time(model),
    )
end

"""
Solve `data` exactly and return the result as a package `SolutionState`, see
[`benchmark_solve`](@ref).
"""
function _benchmark_solve(
    data::_MCFData;
    optimizer=HiGHS.Optimizer,
    time_limit::Union{Nothing,Real}=nothing,
    silent::Bool=true,
)
    instance = _to_instance(data)
    mip = _solve_mip(data; optimizer, time_limit, silent)

    solution, objective_value, relative_gap = if isnothing(mip.node_paths)
        (nothing, Inf, Inf)
    else
        ttg = instance.travel_time_graph.graph
        paths = [
            [code_for(ttg, (string(node), 0)) for node in mip.node_paths[bundle.group]]
            for bundle in instance.bundles
        ]
        sol = SolutionState(paths, instance)
        sol_cost = cost(sol)
        gap =
            iszero(sol_cost) ? sol_cost - mip.objective_bound :
            (sol_cost - mip.objective_bound) / abs(sol_cost)
        (sol, sol_cost, max(0.0, gap))
    end

    return (;
        solution,
        instance,
        objective_value,
        objective_bound=mip.objective_bound,
        relative_gap,
        termination_status=mip.termination_status,
        solve_time=mip.solve_time,
    )
end

"""
$TYPEDSIGNATURES

Solve instance `name` of dataset `c` exactly with a MIP.

Solves the unsplittable multicommodity flow problem, or its fixed-charge network design
variant when `network_design=true`.
`optimizer` defaults to HiGHS and accepts any JuMP optimizer, for instance
`gurobi_optimizer`.
`time_limit` is in seconds.

`objective_value` is `cost(solution)`, or `Inf` without solution.
`objective_bound` is `Inf` if infeasible and `-Inf` if unavailable.
See [`TransportationPlanningOptimization.Problems.benchmark_solve`](@ref) for the returned
fields.
"""
function benchmark_solve(
    c::CanadC,
    name::AbstractString;
    network_design::Bool=false,
    optimizer=HiGHS.Optimizer,
    time_limit::Union{Nothing,Real}=nothing,
    silent::Bool=true,
)
    return _benchmark_solve(
        _load_data(c, name; network_design); optimizer, time_limit, silent
    )
end
