"""
$TYPEDEF

Abstract type for ILS perturbations.

Concrete subtypes must implement [`perturbate!`](@ref).
"""
abstract type AbstractPerturbation end

"""
$TYPEDSIGNATURES

Apply perturbation `p` to `sol`. Returns `(improvement, n_changed)` where
`improvement` is the cost reduction (positive means cheaper) and `n_changed`
is the number of bundles whose paths changed.

If the perturbation degrades cost beyond an internal tolerance, the
implementation must revert `sol` and return `(0.0, 0)`.
"""
function perturbate!(
    sol::Solution,
    instance::Instance,
    p::AbstractPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    return error("perturbate! not implemented for $(typeof(p))")
end
