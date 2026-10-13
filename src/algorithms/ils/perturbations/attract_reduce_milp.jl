"""
$TYPEDEF

Perturbation that pulls bundles onto a shared arc, or pushes them off it, and keeps the
combination that pays with a MILP.

An arc of the `TravelTimeGraph` with a bin cost that carries at least one bundle is drawn at
random. An arc that leaves more than `min_candidate_ratio` of the routed bundles with a new
path is used at once, otherwise the priced arc with the most new paths is used. At most
`MAX_PRICED_ARCS` (20) arcs are priced per call and the pricing stops at half of the
effective time limit, including inside an arc. The effective time limit is the smaller of
the `time_limit` field and the call budget, which is the `time_limit` keyword of
[`perturbate!`](@ref). The solver gets what is left of the call budget after the pricing
and the model build, at most the `time_limit` field.
A call with less than `MIN_MILP_TIME` (1 second) left, before the build or after it,
changes nothing.
Every bundle on the arc gets a "reduce" path, its cheapest elementary path that avoids the
arc.
Every other bundle that can use the arc gets an "attract" path, its cheapest elementary
path forced through it.
Paths respect the forbidden nodes and arcs of the bundle, and a bundle without such a path
is not modeled.
Without finite arc capacities, paths are priced against the current solution as it is, so
the load of the bundle itself is counted in the costs.
With finite capacities, the bundle is removed while its paths are priced.
The arc is a `TravelTimeGraph` arc because bundles share it in relative time, the bins
that decide the cost are on the time-space edges and are all in the model.

The model has one binary variable per bundle that chooses its current path (0) or its new
path (1), and one integer bin variable per time-space edge with a bin cost that one of
these paths uses. The load of the other bundles and reservations is kept fixed. The
objective is the slope-scaled linear cost of the paths plus the bins of the edges, using
the lower bound of each arc cost as its linear relaxation.
The new paths are kept if the real cost increase is at most `tolerance * cost(sol)`,
otherwise the solution is left unchanged. The perturbation also changes nothing when no
priced arc yields any new path.

Multimodal arcs are not supported and raise an `ArgumentError`.

# Fields
$TYPEDFIELDS
"""
@kwdef struct AttractReduceMILPPerturbation{O} <: AbstractPerturbation
    "JuMP optimizer (or optimizer factory) used to solve the MILP"
    optimizer::O = HiGHS.Optimizer
    "time limit of the MILP solve in seconds, it also bounds the arc pricing"
    time_limit::Float64 = 180.0
    "relative MIP gap at which the solve stops"
    mip_gap::Float64 = 1e-3
    "maximum accepted cost increase, as a fraction of the current cost"
    tolerance::Float64 = 0.015
    "minimum fraction of the routed bundles that must get a new path for an arc to be chosen"
    min_candidate_ratio::Float64 = 0.3
    "whether the current routing is given to the solver as a starting solution (off by default so time-limited solves still diversify)"
    warm_start::Bool = false

    function AttractReduceMILPPerturbation{O}(
        optimizer, time_limit, mip_gap, tolerance, min_candidate_ratio, warm_start
    ) where {O}
        0 <= min_candidate_ratio < 1 ||
            throw(ArgumentError("min_candidate_ratio must be in [0, 1)"))
        return new{O}(
            optimizer, time_limit, mip_gap, tolerance, min_candidate_ratio, warm_start
        )
    end
end

function AttractReduceMILPPerturbation(
    optimizer::O, time_limit, mip_gap, tolerance, min_candidate_ratio, warm_start
) where {O}
    return AttractReduceMILPPerturbation{O}(
        optimizer, time_limit, mip_gap, tolerance, min_candidate_ratio, warm_start
    )
end

# Arcs in random order with the routed bundles that could use them: the bundles whose
# arcs contain the arc, which includes the bundles that use it. The arcs are the TTG arcs
# with a bin cost used by a routed bundle, `users[arc]` lists these bundles.
function _attract_reduce_candidates(
    sol::SolutionState, instance::Instance, rng::Random.AbstractRNG
)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    users = Dict{Tuple{Int,Int},Vector{Int}}()
    for (b, path) in enumerate(sol.bundle_paths), k in 1:(length(path) - 1)
        u, v = path[k], path[k + 1]
        cache.ttg_code_to_spatial_code[u] == cache.ttg_code_to_spatial_code[v] && continue
        arc = ttg_edge_arc(cache, u, v)
        isnothing(arc) ||
            isnothing(_bin_packing_cost_of(arc.cost)) ||
            push!(get!(Vector{Int}, users, (u, v)), b)
    end
    could_use = Dict(arc => Int[] for arc in keys(users))
    for (b, path) in enumerate(sol.bundle_paths)
        isempty(path) && continue
        for arc in ttg.bundle_arcs[b]
            haskey(could_use, arc) && push!(could_use[arc], b)
        end
    end
    return Random.shuffle(rng, sort!(collect(keys(users)))), users, could_use
end

# New paths of `bundle_idxs` for the TTG arc `arc`: reduce paths for the bundles in `users`,
# attract paths for the others. The bundles missing from the result have no new path.
# `adjacencies` caches the bundle adjacencies across arcs. The pricing stops early, with a
# partial result, once the bundles left cannot bring the count above `to_beat` or once
# `time()` passes `deadline`. With `remove_bundle=false` the paths are priced against `sol`
# as it is, so the load of a bundle on its current edges is counted in its own new path
# costs. That would count it twice in the capacity check, so `remove_bundle` is on whenever
# an arc has a finite capacity: the bundle is removed while it is priced, then restored.
function _attract_reduce_paths(
    sol::SolutionState,
    instance::Instance,
    arc::Tuple{Int,Int},
    bundle_idxs,
    users;
    adjacencies::Dict{Int,Dict{Int,Vector{Int}}}=Dict{Int,Dict{Int,Vector{Int}}}(),
    to_beat::Int=0,
    deadline::Float64=Inf,
    remove_bundle::Bool=_has_finite_capacity(instance),
)
    ttg = instance.travel_time_graph
    mode_selector = CheapestMode()
    buffer = BinPackingBuffer()
    workspace = DijkstraWorkspace(Graphs.nv(ttg.graph))
    paths = Dict{Int,Vector{Int}}()
    for (i, b) in enumerate(bundle_idxs)
        length(paths) + length(bundle_idxs) - i + 1 <= to_beat && break
        time() > deadline && break
        old_path = sol.bundle_paths[b]
        snapshots =
            remove_bundle ? _snapshot_path_assignments(sol, instance, b, old_path) : nothing
        remove_bundle && remove_bundle_path!(sol, instance, b)
        adj = get!(() -> _bundle_adjacency(ttg, b), adjacencies, b)
        path = if b in users
            reduce_path = _lazy_bundle_path!(
                sol,
                instance,
                b,
                ttg.origin_codes[b],
                ttg.destination_codes[b],
                mode_selector,
                buffer,
                adj;
                workspace,
                exclude=arc,
                deadline,
            )
            _remove_shortcuts_from_path!(reduce_path, ttg)
            reduce_path
        else
            _lazy_forced_path!(
                sol, instance, b, arc, mode_selector, buffer, adj; workspace, deadline
            )
        end
        isnothing(snapshots) || _restore_path_assignments!(sol, b, old_path, snapshots)
        (isempty(path) || path == old_path) || (paths[b] = path)
    end
    return paths
end

# Number of arcs priced at most by one call.
const MAX_PRICED_ARCS = 20

# The first arc, in random order, that leaves more than `min_candidate_ratio` of the routed
# bundles with a new path, with these paths. When no priced arc reaches that count, the arc
# with the most new paths is used. `nothing` if no priced arc has any path. At most
# `MAX_PRICED_ARCS` arcs are priced, and the pricing stops once half of `time_limit` is
# spent (the effective limit of the call, the field `p.time_limit` by default), inside an
# arc too. The first arc is priced, but only up to that time.
function _select_attract_reduce_arc(
    sol::SolutionState,
    instance::Instance,
    p::AttractReduceMILPPerturbation,
    rng::Random.AbstractRNG;
    time_limit::Real=p.time_limit,
    start::Real=time(),
)
    n_routed = count(!isempty, sol.bundle_paths)
    threshold = p.min_candidate_ratio * n_routed
    arcs, users, could_use = _attract_reduce_candidates(sol, instance, rng)
    adjacencies = Dict{Int,Dict{Int,Vector{Int}}}()
    best = Dict{Int,Vector{Int}}()
    n_priced = 0
    deadline = start + Float64(time_limit) / 2
    remove_bundle = _has_finite_capacity(instance)
    for arc in arcs
        n_priced >= MAX_PRICED_ARCS && break
        n_priced > 0 && time() > deadline && break
        # Cheap upper bound first, the paths are only computed when it passes.
        length(could_use[arc]) > max(threshold, length(best)) || continue
        n_priced += 1
        paths = _attract_reduce_paths(
            sol,
            instance,
            arc,
            could_use[arc],
            Set(users[arc]);
            adjacencies,
            to_beat=length(best),
            deadline,
            remove_bundle,
        )
        length(paths) > threshold && return paths
        length(paths) > length(best) && (best = paths)
    end
    return isempty(best) ? nothing : best
end

"""
$TYPEDSIGNATURES

Build the model of the `modeled` bundles, each choosing between its current path and its
`new_paths`. Returns the model and the binary variables `z` (one per modeled bundle). With
`p.warm_start`, the current routing is set as the start values.
"""
function _attract_reduce_model(
    p::AttractReduceMILPPerturbation,
    sol::SolutionState,
    instance::Instance,
    modeled::Vector{Int},
    new_paths,
)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    model = _milp_model(p.optimizer, p.mip_gap)
    z = @variable(model, [1:length(modeled)], Bin)
    tau = Dict{Tuple{Int,Int},JuMP.VariableRef}()
    loads = Dict{Tuple{Int,Int},JuMP.AffExpr}()
    edge_arc = Dict{Tuple{Int,Int},Any}()
    objective = JuMP.AffExpr(0.0)

    for (i, b) in enumerate(modeled)
        bundle = instance.bundles[b]
        # Moving to the new path (z = 1) removes the old path and adds the new one.
        for (path, sign) in ((sol.bundle_paths[b], -1.0), (new_paths[b], 1.0))
            for k in 1:(length(path) - 1)
                u, v = path[k], path[k + 1]
                cache.ttg_code_to_spatial_code[u] == cache.ttg_code_to_spatial_code[v] &&
                    continue
                arc = ttg_edge_arc(cache, u, v)
                JuMP.add_to_expression!(
                    objective, sign * _milp_arc_coefficient(instance, bundle, u, v), z[i]
                )
                _milp_is_packed(arc) || continue
                scaling = get(ttg.cost_scaling, ttg_edge_key(cache, u, v), 1.0)
                for order in bundle.orders
                    e = (
                        project_to_time_space_graph(u, order, instance),
                        project_to_time_space_graph(v, order, instance),
                    )
                    JuMP.add_to_expression!(
                        get!(JuMP.AffExpr, loads, e), sign * order.total_size, z[i]
                    )
                    edge_arc[e] = arc
                    _milp_add_bins!(model, tau, objective, e, arc, scaling)
                end
            end
        end
    end

    background = Dict(e => _milp_current_load(sol, e) for e in keys(loads))
    _milp_add_packing!(model, loads, tau, edge_arc, background)
    @objective(model, Min, objective)
    if p.warm_start
        JuMP.set_start_value.(z, 0.0)
        _milp_start_bins!(tau, sol, instance)
    end
    return model, z
end

"""
$TYPEDSIGNATURES

Pull bundles onto a shared arc or push them off it, see
[`AttractReduceMILPPerturbation`](@ref).
"""
function perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::AttractReduceMILPPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
)
    any(a -> a isa MultiModalArc, values(instance.index_cache.edge_group_to_arc)) && throw(
        ArgumentError("AttractReduceMILPPerturbation does not support multimodal arcs")
    )
    start = time()
    reject(outcome; fields...) = _log_perturbation(verbose, p, outcome, (0.0, 0); fields...)
    time_limit >= MIN_MILP_TIME || return reject("rejected: not enough time"; time_limit)
    new_paths = _select_attract_reduce_arc(
        sol, instance, p, rng; time_limit=min(p.time_limit, time_limit), start
    )
    isnothing(new_paths) && return reject("rejected: no candidate arc")
    modeled = sort!(collect(keys(new_paths)))
    time_limit - (time() - start) >= MIN_MILP_TIME ||
        return reject("rejected: not enough time"; n_modeled=length(modeled))
    build_start = time()
    model, z = _attract_reduce_model(p, sol, instance, modeled, new_paths)
    _milp_attach!(model)
    build_time = time() - build_start
    left = time_limit - (time() - start)
    left >= MIN_MILP_TIME ||
        return reject("rejected: not enough time"; n_modeled=length(modeled), build_time)
    JuMP.set_time_limit_sec(model, min(p.time_limit, left))
    solve_start = time()
    JuMP.optimize!(model)
    fields = (;
        n_modeled=length(modeled), _milp_fields(model, build_time, time() - solve_start)...
    )
    JuMP.has_values(model) || return reject("rejected: no solution"; fields...)

    changed = modeled[JuMP.value.(z) .> 0.5]
    isempty(changed) && return reject("rejected: no change"; fields...)
    outcome = Ref("")
    result = _reroute_bundles!(
        sol, instance, changed; tolerance=p.tolerance, outcome, failure="capacity"
    ) do s, inst, snapshots
        for b in changed
            _add_fixed_path!(s, inst, b, new_paths[b], snapshots)
        end
        return _fits_capacities(s, inst, snapshots)
    end
    return _log_perturbation(verbose, p, outcome[], result; fields...)
end
