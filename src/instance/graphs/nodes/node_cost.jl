"""
$TYPEDEF

Abstract type for per-node cost contributions. Mirrors [`AbstractArcCostFunction`](@ref):
node costs participate in path scoring exactly like arc costs, so they expose the same
`evaluate` / `incremental_cost` / `lower_bound_incremental_cost` interface.

Concrete subtypes **must** implement:
- `evaluate(c::T, commodities) -> Float64`: total node cost for `commodities` passing
through the node.

Concrete subtypes **may** overload (defaults are provided):
- `incremental_cost(c::T, existing, new) -> Float64`: marginal cost of adding `new` to a
  node that already holds `existing`.
  Defaults to `evaluate(c, existing ∪ new) - evaluate(c, existing)`.
  Overload it when a closed form is cheaper than two `evaluate` calls (and to avoid the
  `vcat` allocation).
- `lower_bound_incremental_cost(c::T, existing, new) -> Float64`: a relaxation of
  `incremental_cost` used by the lower-bound / filtering pass.
  Defaults to `incremental_cost`.
  Overload it only when the lower bound differs from the true cost (it must under-estimate
  for the bound to stay valid).

The default [`NoNodeCost`](@ref) returns `0.0` for all of these.
"""
abstract type AbstractNodeCostFunction end

"""
$TYPEDSIGNATURES

Default marginal node cost: evaluate the union and subtract the existing total.
It is recommended to specialize this method when possible, for efficiency reasons.
"""
function incremental_cost(
    node_f::AbstractNodeCostFunction, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return evaluate(node_f, vcat(existing, new)) - evaluate(node_f, existing)
end

"""
$TYPEDSIGNATURES

Lower-bound variant of [`incremental_cost`](@ref) for node costs. By default it forwards to
`incremental_cost`.
Specialize this for node costs whose lower bound differs from their actual cost.
"""
function lower_bound_incremental_cost(
    node_f::AbstractNodeCostFunction, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return incremental_cost(node_f, existing, new)
end

"""
$TYPEDEF

Default zero-valued node cost.
Use this node cost when there is no incurred cost at the considered node
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

"""
$TYPEDSIGNATURES

Fast path when `new_total_size` is precomputed. Falls back to `incremental_cost`.
"""
function incremental_cost_with_size(
    node_f::AbstractNodeCostFunction, existing::Vector{C}, new::Vector{C}, ::Float64
) where {C<:LightCommodity}
    return incremental_cost(node_f, existing, new)
end

"""
$TYPEDSIGNATURES

Generic fallback for node costs: ignores the buffer and forwards to `incremental_cost`.
"""
function incremental_cost!(
    ::BinPackingBuffer,
    node_f::AbstractNodeCostFunction,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return incremental_cost(node_f, existing, new)
end
