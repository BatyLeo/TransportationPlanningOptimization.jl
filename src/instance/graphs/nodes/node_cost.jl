"""
$TYPEDEF

Abstract type for per-node cost contributions. Mirrors [`AbstractArcCostFunction`](@ref):
node costs participate in path scoring exactly like arc costs, so they expose the same
`evaluate` / `incremental_cost` / `lower_bound_incremental_cost` interface.

A node cost is charged once per incoming time-space arc, at that arc's head node, on
the arc's full load (across modes for a multi-modal edge). The origin of a bundle's
path is never charged, and a node reached through several incoming arcs is charged
once per arc.

Concrete subtypes **must** implement:
- `evaluate(c::T, commodities) -> Float64`: total node cost for `commodities` passing
  through the node. Must return `0.0` on an empty `commodities` vector (validated when
  the `Instance` is built, since a fresh or emptied edge assignment starts at
  `node_cost = 0.0`).

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

# ─── NoNodeCost ──────────────────────────────────────────────────────────────

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

# ─── LinearNodeCost ──────────────────────────────────────────────────────────

"""
$TYPEDEF

Linear node cost proportional to total volume.
The formula is `cost_per_unit_size * sum(commodity.size)`.

$TYPEDFIELDS
"""
struct LinearNodeCost <: AbstractNodeCostFunction
    "unit cost per unit of size"
    cost_per_unit_size::Float64
end

function evaluate(c::LinearNodeCost, comms::Vector{<:LightCommodity})
    return c.cost_per_unit_size * sum(x.size for x in comms; init=0.0)
end

function incremental_cost(
    c::LinearNodeCost, _::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return evaluate(c, new)
end
