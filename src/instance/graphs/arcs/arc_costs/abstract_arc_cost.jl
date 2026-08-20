"""
$TYPEDEF

Abstract base type for cost functions defined on network arcs.
Concrete subtypes determine how load/size on an arc is translated into cost.

Concrete subtypes **must** implement:
- `evaluate(arc_f::T, commodities; presorted=false) -> Float64`: total arc cost for `commodities`.

Concrete subtypes **may** overload (sensible defaults are provided in terms of `evaluate`,
see `incremental_cost` / `lower_bound_incremental_cost`):
- `incremental_cost(arc_f::T, existing, new) -> Float64`: marginal cost of adding `new` to
  an arc that already holds `existing`.
  Defaults to `evaluate(arc_f, existing ∪ new) - evaluate(arc_f, existing)`.
  Overload it when a closed form is cheaper (e.g. [`LinearArcCost`](@ref), [`BinPackingArcCost`](@ref)).
- `lower_bound_incremental_cost(arc_f::T, existing, new) -> Float64`: a relaxation of
  `incremental_cost` used by the lower-bound / filtering pass. Defaults to `incremental_cost`.
  Overload it only when the lower bound differs from the true cost and must under-estimate it
  (e.g. [`BinPackingArcCost`](@ref), which relaxes the integer bin count to a fractional one).
"""
abstract type AbstractArcCostFunction end

"""
$TYPEDSIGNATURES

Fallback for cost function types that have not yet implemented `evaluate`.
Throws to prevent silently incorrect (zero) costs during development.
"""
function evaluate(
    arc_f::AbstractArcCostFunction, ::Vector{<:LightCommodity}; presorted::Bool=false
)
    return throw(
        ArgumentError("evaluate not implemented for cost function of type $(typeof(arc_f))")
    )
end
