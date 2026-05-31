"""
$TYPEDEF

Abstract type for per-node cost contributions. Mirrors [`AbstractArcCostFunction`](@ref):
node costs participate in path scoring exactly like arc costs, so they expose the same
`evaluate` / `incremental_cost` / `lower_bound_incremental_cost` interface.

Concrete subtypes **must** implement:
- `evaluate(c::T, commodities) -> Float64` — total node cost for `commodities`.

Concrete subtypes **may** overload (sensible defaults are provided in terms of `evaluate`):
- `incremental_cost(c::T, existing, new) -> Float64` — marginal cost of adding `new` to a
  node that already holds `existing`. Defaults to `evaluate(c, existing ∪ new) - evaluate(c, existing)`.
  Overload it when a closed form is cheaper than two `evaluate` calls (and to avoid the
  `vcat` allocation in the hot routing loop).
- `lower_bound_incremental_cost(c::T, existing, new) -> Float64` — a relaxation of
  `incremental_cost` used by the lower-bound / filtering pass. Defaults to `incremental_cost`.
  Overload it only when the lower bound differs from the true cost (it must under-estimate
  for the bound to stay valid).

The default [`NoNodeCost`](@ref) returns `0.0` for all of these.
"""
abstract type AbstractNodeCostFunction end

"""
$TYPEDSIGNATURES

Default marginal node cost: evaluate the union and subtract the existing total. Any
`AbstractNodeCostFunction` subtype inherits this from its `evaluate`; specialize for
efficiency.
"""
function incremental_cost(
    node_f::AbstractNodeCostFunction, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return evaluate(node_f, vcat(existing, new)) - evaluate(node_f, existing)
end

"""
$TYPEDSIGNATURES

Lower-bound variant of [`incremental_cost`](@ref) for node costs. By default it forwards to
`incremental_cost`, so any new subtype inherits a sane default. Specialize this for node
costs whose lower bound differs from their actual cost.
"""
function lower_bound_incremental_cost(
    node_f::AbstractNodeCostFunction, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return incremental_cost(node_f, existing, new)
end

"""
$TYPEDEF

Default zero-valued node cost.
"""
struct NoNodeCost <: AbstractNodeCostFunction end

evaluate(::NoNodeCost, ::Vector{<:LightCommodity}) = 0.0

# Explicit zero specializations: avoid the `vcat` allocation the generic fallback would
# incur on every routing-loop call for the (common) no-op node cost.
function incremental_cost(::NoNodeCost, ::Vector{C}, ::Vector{C}) where {C<:LightCommodity}
    return 0.0
end

function lower_bound_incremental_cost(
    ::NoNodeCost, ::Vector{C}, ::Vector{C}
) where {C<:LightCommodity}
    return 0.0
end
