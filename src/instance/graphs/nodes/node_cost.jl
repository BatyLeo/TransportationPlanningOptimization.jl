"""
$TYPEDEF

Abstract type for per-node cost contributions.

Concrete subtypes implement:
- `evaluate(c::T, commodities) -> Float64`
- `incremental_cost(c::T, existing, new) -> Float64`
- `lower_bound_incremental_cost(c::T, existing, new) -> Float64`

The default `NoNodeCost` returns `0.0` for all of these.
"""
abstract type AbstractNodeCostFunction end

"""
$TYPEDEF

Default zero-valued node cost.
"""
struct NoNodeCost <: AbstractNodeCostFunction end

evaluate(::NoNodeCost, ::Vector{<:LightCommodity}) = 0.0

function incremental_cost(::NoNodeCost, ::Vector{C}, ::Vector{C}) where {C<:LightCommodity}
    return 0.0
end

function lower_bound_incremental_cost(
    ::NoNodeCost, ::Vector{C}, ::Vector{C}
) where {C<:LightCommodity}
    return 0.0
end
