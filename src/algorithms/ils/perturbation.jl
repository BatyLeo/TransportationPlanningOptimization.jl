"""
$TYPEDEF

Abstract type for ILS perturbations.

Concrete subtypes must implement [`perturbate!`](@ref), including its `rng`, `verbose` and
`time_limit` and `mode_selector` keyword arguments.
"""
abstract type AbstractPerturbation end

"""
$TYPEDSIGNATURES

Apply perturbation `p` to `sol`. Returns `(cost_increase, n_changed)` where
`cost_increase` is the cost after minus the cost before (positive means the solution
got more expensive) and `n_changed` is the number of bundles whose paths changed.

If the perturbation degrades cost beyond an internal tolerance, the
implementation must revert `sol` and return `(0.0, 0)`.

`time_limit` is the number of seconds this call may use, which the loop sets to the time
left in the ILS loop and in the current perturbation phase. The loop starts no call with
less than `MIN_CALL_TIME` (1 second) left, or half the shorter limit when a limit is under
2 seconds, see [`iterated_local_search!`](@ref).
Implementations should respect it as far as they can and return `(0.0, 0)` without
changing `sol` when it is too short to be useful.

`mode_selector` is the [`AbstractModeSelector`](@ref) of the ILS, the same as for the rest
of the pipeline (see [`solve`](@ref)). [`iterated_local_search!`](@ref) passes its own to
every perturbation, and an implementation must use it for any insertion or commit of paths
(for instance `TransportationPlanningOptimization.add_bundle_path!(...; mode_selector)`),
so that a solution built under one selector is never repacked under another.

With `verbose=true`, an implementation should log one line per call (a cheap perturbation
called many times per phase may log its rejected calls at debug level).
"""
function perturbate!(
    sol::SolutionState,
    instance::Instance,
    p::AbstractPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
    time_limit::Real=Inf,
    mode_selector::AbstractModeSelector=CheapestMode(),
)
    return error("perturbate! not implemented for $(typeof(p))")
end

"""
$TYPEDSIGNATURES

Whether perturbation `p` can run on `instance`, `true` by default.

[`iterated_local_search!`](@ref) keeps only the perturbations that support the instance and
skips the others. A custom perturbation may overload it, for instance to opt out of
instances with multimodal arcs.
"""
supports_instance(::AbstractPerturbation, ::Instance) = true
