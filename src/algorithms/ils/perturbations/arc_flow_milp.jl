"""
$TYPEDEF

Perturbation that reroutes several groups of bundles at once with an arc-flow MILP.

Groups of routed bundles (by default one per destination node) are drawn at random and
their bundles are added in random order while the model stays within `max_variables`
variables, until it is above 90% of it. The model has one binary variable per
bundle and allowed `TravelTimeGraph` arc, flow conservation and elementarity constraints
per bundle, and one integer bin variable per time-space edge with a bin cost.
The load of the other bundles is kept fixed. The objective is the slope-scaled linear
cost of the paths plus the bins of the shared edges, using the lower bound of each arc
cost as its linear relaxation.
The new paths are kept if the real cost increase is at most
`tolerance * cost(sol)`, otherwise the solution is left unchanged.

Multimodal arcs are not supported and raise an `ArgumentError`.
The solver time limit is the smaller of the `time_limit` field and the call budget left.
The call budget is the `time_limit` keyword of [`perturbate!`](@ref), minus the time
already spent on the selection and the model build (the copy to the solver included).
A call with less than `MIN_MILP_TIME` (1 second) left, before or after the build, changes
nothing.
HiGHS presolve can exceed the `time_limit` field on large models, so with HiGHS the
variable cap is what bounds the runtime.

# Fields
$TYPEDFIELDS
"""
@kwdef struct ArcFlowMILPPerturbation{F,O} <: AbstractPerturbation
    "function mapping a [`Bundle`](@ref) to its group key"
    group_by::F = b -> b.destination_id
    "JuMP optimizer (or optimizer factory) used to solve the MILP"
    optimizer::O = HiGHS.Optimizer
    "maximum number of variables of the model (arc and bin variables)"
    max_variables::Int = 150_000
    "time limit of the MILP solve in seconds"
    time_limit::Float64 = 180.0
    "relative MIP gap at which the solve stops"
    mip_gap::Float64 = 1e-3
    "maximum accepted cost increase, as a fraction of the current cost"
    tolerance::Float64 = 0.015
    "whether the current routing is given to the solver as a starting solution (useful with a strong solver or small variable caps, off by default so time-limited solves still diversify)"
    warm_start::Bool = false
end

# Allowed TTG arcs `u[i] -> v[i]` of a bundle, as parallel vectors. `edges[i]` holds the
# time-space edges of the orders when the arc is packed (bins or a finite capacity), and
# `binned[i]` tells whether the arc has a bin cost. Shortcut (waiting) arcs cost nothing.
struct _MilpArcs
    u::Vector{Int}
    v::Vector{Int}
    edges::Vector{Vector{Tuple{Int,Int}}}
    binned::Vector{Bool}
end

function _milp_bundle_arcs(instance::Instance, bundle_idx::Int)
    cache = instance.index_cache
    bundle = instance.bundles[bundle_idx]
    # Same filter as the cost matrix update: forbidden arcs and nodes are not allowed.
    fn, fa = _forbidden_codes(instance, bundle)
    arcs = _MilpArcs(Int[], Int[], Vector{Tuple{Int,Int}}[], Bool[])
    for (u, v) in instance.travel_time_graph.bundle_arcs[bundle_idx]
        su = cache.ttg_code_to_spatial_code[u]
        sv = cache.ttg_code_to_spatial_code[v]
        ((su, sv) in fa || su in fn || sv in fn) && continue
        arc = su == sv ? nothing : ttg_edge_arc(cache, u, v)
        (su != sv && isnothing(arc)) && continue
        packed = !isnothing(arc) && _milp_is_packed(arc)
        push!(arcs.u, u)
        push!(arcs.v, v)
        push!(
            arcs.edges,
            packed ?
            [
                (
                    project_to_time_space_graph(u, order, instance),
                    project_to_time_space_graph(v, order, instance),
                ) for order in bundle.orders
            ] : Tuple{Int,Int}[],
        )
        push!(arcs.binned, packed && !isnothing(_bin_packing_cost_of(arc.cost)))
    end
    return arcs
end

# Whether the arc of a TTG edge adds a packing constraint (bins or a finite capacity).
function _milp_is_packed(arc)
    return !isnothing(_bin_packing_cost_of(arc.cost)) || _finite_capacity(arc)
end

# Draw groups at random, then their bundles in random order, and keep each bundle whose
# variables (arcs and new bin edges) still fit within `max_variables`. Stop after the first
# group that brings the count above 90% of it. Groups are only scanned when reached.
function _select_milp_bundles(
    sol::SolutionState,
    instance::Instance,
    p::ArcFlowMILPPerturbation,
    rng::Random.AbstractRNG,
)
    selected = Int[]
    arcs_of = Dict{Int,_MilpArcs}()
    bin_edges = Set{Tuple{Int,Int}}()
    n_variables = 0
    for group in Random.shuffle(rng, _routed_groups(sol, instance, p.group_by))
        for b in Random.shuffle(rng, group)
            arcs = _milp_bundle_arcs(instance, b)
            new_edges = Set{Tuple{Int,Int}}()
            for (i, edges) in enumerate(arcs.edges)
                arcs.binned[i] || continue
                for e in edges
                    e in bin_edges || push!(new_edges, e)
                end
            end
            n_bundle = length(arcs.u) + length(new_edges)
            n_variables + n_bundle <= p.max_variables || continue
            push!(selected, b)
            arcs_of[b] = arcs
            union!(bin_edges, new_edges)
            n_variables += n_bundle
        end
        n_variables > 0.9 * p.max_variables && break
    end
    return selected, arcs_of
end

# Load of the time-space edges of the selected bundles that does not come from them.
function _milp_background_loads(sol::SolutionState, instance::Instance, selected)
    removed = Dict{Tuple{Int,Int},Float64}()
    for b in selected
        _foreach_path_edge(
            instance, instance.bundles[b], sol.bundle_paths[b]
        ) do e, _, order
            removed[e] = get(removed, e, 0.0) + order.total_size
            return 0.0
        end
    end
    return removed
end

"""
$TYPEDSIGNATURES

Build the arc-flow model for the `selected` bundles. Returns the model and its arc variables
`x` (listed bundle by bundle in the order of `arcs_of[b]`). With `p.warm_start`, the current
routing of the bundles is set as the start values of the variables.
"""
function _arc_flow_model(
    p::ArcFlowMILPPerturbation,
    sol::SolutionState,
    instance::Instance,
    selected::Vector{Int},
    arcs_of,
)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    removed = _milp_background_loads(sol, instance, selected)

    model = _milp_model(p.optimizer, p.mip_gap)

    x = @variable(model, [1:sum(b -> length(arcs_of[b].u), selected)], Bin)
    # Bin variables count the bins of the whole edge, background included, so the relative
    # gap is relative to a large constant. `tau`, `loads` and `edge_arc` hold the bin
    # variables, the load terms and the arc of the packed time-space edges.
    tau = Dict{Tuple{Int,Int},JuMP.VariableRef}()
    loads = Dict{Tuple{Int,Int},JuMP.AffExpr}()
    edge_arc = Dict{Tuple{Int,Int},Any}()
    objective = JuMP.AffExpr(0.0)

    i = 0
    for b in selected
        bundle = instance.bundles[b]
        origin = ttg.origin_codes[b]
        destination = ttg.destination_codes[b]
        balance = Dict{Int,JuMP.AffExpr}()
        entering = Dict{Int,JuMP.AffExpr}()
        arcs = arcs_of[b]
        for k in eachindex(arcs.u)
            i += 1
            u, v = arcs.u[k], arcs.v[k]
            JuMP.add_to_expression!(get!(JuMP.AffExpr, balance, u), 1.0, x[i])
            JuMP.add_to_expression!(get!(JuMP.AffExpr, balance, v), -1.0, x[i])
            sv = cache.ttg_code_to_spatial_code[v]
            cache.ttg_code_to_spatial_code[u] == sv && continue
            arc = ttg_edge_arc(cache, u, v)
            JuMP.add_to_expression!(get!(JuMP.AffExpr, entering, sv), 1.0, x[i])

            JuMP.add_to_expression!(
                objective, _milp_arc_coefficient(instance, bundle, u, v), x[i]
            )

            isempty(arcs.edges[k]) && continue
            scaling = get(ttg.cost_scaling, ttg_edge_key(cache, u, v), 1.0)
            for (order, e) in zip(bundle.orders, arcs.edges[k])
                JuMP.add_to_expression!(
                    get!(JuMP.AffExpr, loads, e), order.total_size, x[i]
                )
                edge_arc[e] = arc
                _milp_add_bins!(model, tau, objective, e, arc, scaling)
            end
        end
        for (node, expr) in balance
            @constraint(model, expr == (node == origin) - (node == destination))
        end
        # A path visits each physical node at most once, and never returns to its origin.
        origin_node = cache.ttg_code_to_spatial_code[origin]
        for (node, expr) in entering
            @constraint(model, expr <= (node == origin_node ? 0 : 1))
        end
    end

    background = Dict(
        e => max(0.0, _milp_current_load(sol, e) - get(removed, e, 0.0)) for
        e in keys(loads)
    )
    _milp_add_packing!(model, loads, tau, edge_arc, background)
    @objective(model, Min, objective)
    p.warm_start && _set_start_values!(model, x, tau, sol, instance, selected, arcs_of)
    return model, x
end

# Start values of the current routing: the arcs of each path, completed with the shortcut
# arcs stripped from stored paths so that the flow goes from the origin to the destination,
# and the bins needed by the current load of each edge. Nothing is set when some path cannot
# be completed.
function _set_start_values!(model, x, tau, sol, instance, selected, arcs_of)
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    on_arcs = Set{Tuple{Int,Int}}[]
    for b in selected
        arcs = arcs_of[b]
        waiting = Dict(
            arcs.u[k] => arcs.v[k] for
            k in eachindex(arcs.u) if spatial[arcs.u[k]] == spatial[arcs.v[k]]
        )
        path = sol.bundle_paths[b]
        isempty(path) && return nothing
        on = Set(zip(path[1:(end - 1)], path[2:end]))
        for (start, stop) in
            ((ttg.origin_codes[b], path[1]), (path[end], ttg.destination_codes[b]))
            while start != stop
                next = get(waiting, start, 0)
                next == 0 && return nothing
                push!(on, (start, next))
                start = next
            end
        end
        push!(on_arcs, on)
    end
    i = 0
    for (b, on) in zip(selected, on_arcs)
        arcs = arcs_of[b]
        for k in eachindex(arcs.u)
            i += 1
            JuMP.set_start_value(x[i], (arcs.u[k], arcs.v[k]) in on ? 1.0 : 0.0)
        end
    end
    _milp_start_bins!(tau, sol, instance)
    return nothing
end

# Paths of the selected bundles read from the arc variables, `nothing` when a path is not a
# single elementary chain to the sink.
function _arc_flow_paths(instance::Instance, selected, arcs_of, x_values)
    ttg = instance.travel_time_graph
    spatial = instance.index_cache.ttg_code_to_spatial_code
    paths = Dict{Int,Vector{Int}}()
    i = 0
    for b in selected
        next = Dict{Int,Vector{Int}}()
        arcs = arcs_of[b]
        for k in eachindex(arcs.u)
            i += 1
            x_values[i] > 0.5 && push!(get!(Vector{Int}, next, arcs.u[k]), arcs.v[k])
        end
        destination = ttg.destination_codes[b]
        path = [ttg.origin_codes[b]]
        while path[end] != destination
            successors = get(next, path[end], Int[])
            length(successors) == 1 && length(path) <= length(arcs.u) || break
            push!(path, only(successors))
        end
        path[end] == destination && is_elementary_path(path, spatial) || return nothing
        _remove_shortcuts_from_path!(path, ttg)
        paths[b] = path
    end
    return paths
end

"""
$TYPEDSIGNATURES

Reroute the routed bundles of random groups with an arc-flow MILP, see
[`ArcFlowMILPPerturbation`](@ref).
"""
function perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::ArcFlowMILPPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
)
    any(a -> a isa MultiModalArc, values(instance.index_cache.edge_group_to_arc)) &&
        throw(ArgumentError("ArcFlowMILPPerturbation does not support multimodal arcs"))
    start = time()
    reject(outcome; fields...) = _log_perturbation(verbose, p, outcome, (0.0, 0); fields...)
    time_limit >= MIN_MILP_TIME || return reject("rejected: not enough time"; time_limit)
    selected, arcs_of = _select_milp_bundles(sol, instance, p, rng)
    isempty(selected) && return reject("rejected: no bundle selected")
    time_limit - (time() - start) >= MIN_MILP_TIME ||
        return reject("rejected: not enough time"; n_bundles=length(selected))
    build_start = time()
    model, x = _arc_flow_model(p, sol, instance, selected, arcs_of)
    _milp_attach!(model)
    build_time = time() - build_start
    left = time_limit - (time() - start)
    left >= MIN_MILP_TIME ||
        return reject("rejected: not enough time"; n_bundles=length(selected), build_time)
    JuMP.set_time_limit_sec(model, min(p.time_limit, left))
    solve_start = time()
    JuMP.optimize!(model)
    fields = (;
        n_bundles=length(selected), _milp_fields(model, build_time, time() - solve_start)...
    )
    JuMP.has_values(model) || return reject("rejected: no solution"; fields...)

    # The model assumed the new routing of every selected bundle, so one invalid path
    # cannot be mixed with the others (a finite capacity could be exceeded).
    paths = _arc_flow_paths(instance, selected, arcs_of, JuMP.value.(x))
    isnothing(paths) && return reject("rejected: invalid path"; fields...)
    changed = [b for b in selected if paths[b] != sol.bundle_paths[b]]
    isempty(changed) && return reject("rejected: no change"; fields...)

    outcome = Ref("")
    result = _reroute_bundles!(
        sol, instance, changed; tolerance=p.tolerance, outcome, failure="capacity"
    ) do s, inst, snapshots
        for b in changed
            _add_fixed_path!(s, inst, b, paths[b], snapshots)
        end
        return _fits_capacities(s, inst, snapshots)
    end
    return _log_perturbation(verbose, p, outcome[], result; fields...)
end
