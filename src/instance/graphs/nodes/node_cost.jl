"""
$TYPEDEF

Abstract type for per-node cost contributions. Used by
`compute_ttg_edge_incremental_cost` (and the LB / filtering variants) to add
a destination-node cost on each traversed TTG edge.

Concrete subtypes implement:
- `evaluate(c::T, commodities) -> Float64`
- `incremental_cost(c::T, existing, new) -> Float64`
- `lower_bound_incremental_cost(c::T, existing, new) -> Float64`

The default `NoNodeCost` returns `0.0` for all of these.
"""
abstract type AbstractNodeCostFunction end

"""
$TYPEDEF

Zero-valued node cost. Default for `NetworkNode.node_cost` when the caller
does not provide one. Used so the `compute_ttg_edge_*` integration is
unconditional.
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
