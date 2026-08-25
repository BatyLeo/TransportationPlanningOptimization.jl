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

"""
$TYPEDSIGNATURES

Compute the additional cost of adding `new_commodities` to an arc that already contains
`existing_commodities`.
Default implementation: evaluate total and subtract.
"""
function incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    all_commodities = vcat(existing_commodities, new_commodities)
    return evaluate(arc_f, all_commodities) - evaluate(arc_f, existing_commodities)
end

function incremental_cost(
    arc_f::AbstractArcCostFunction, ::Nothing, new_commodities::Vector{<:LightCommodity}
)
    return evaluate(arc_f, new_commodities)
end

"""
$TYPEDSIGNATURES

Fast path for cost functions whose incremental cost depends only on the total
size of the new commodities (not on individual commodity attributes or on the
existing commodities).

The default falls back to `incremental_cost`.
Specialize this for any `AbstractArcCostFunction` or `AbstractNodeCostFunction`
whose incremental cost is a function of the new total size alone.
"""
function incremental_cost_with_size(
    arc_f::AbstractArcCostFunction, existing::Vector{C}, new::Vector{C}, ::Float64
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing, new)
end

"""
$TYPEDSIGNATURES

Lower-bound variant of `incremental_cost`. By default it forwards to
`incremental_cost`, so any new `AbstractArcCostFunction` subtype automatically
inherits a sane default. Specialize this for cost functions whose lower bound
differs from their actual cost.
"""
function lower_bound_incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing_commodities, new_commodities)
end

"""
$TYPEDSIGNATURES

Generic fallback: ignores the buffer and forwards to `incremental_cost`.
Only `BinPackingArcCost` and `SumArcCost` specialize this to reuse the buffer.
"""
function incremental_cost!(
    ::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing, new)
end

function incremental_cost!(
    ::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    ::Nothing,
    new::Vector{<:LightCommodity};
    n_existing::Int=-1,
)
    return incremental_cost(arc_f, nothing, new)
end

"""
$TYPEDSIGNATURES

Generic fallback for frozen-bin incremental cost. Non-bin-packing cost functions
ignore the bins and forward to `incremental_cost_with_size` (when `new_total_size`
is available) or `incremental_cost!`.
Only `BinPackingArcCost` specializes this to actually use the frozen bins.
"""
function frozen_incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    ::AbstractVector{<:Bin},
    existing_comms::Vector{C},
    new::Vector{C},
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    if isnan(new_total_size)
        return incremental_cost!(buffer, arc_f, existing_comms, new)
    end
    return incremental_cost_with_size(arc_f, existing_comms, new, new_total_size)
end
