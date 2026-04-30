"""
$TYPEDEF

Per-edge assignment payload stored in `Solution.assignments`. Concrete subtypes:
- `SingleAssignment{C}` for edges carrying a `NetworkArc`.
- `MultiAssignment{C}` for edges carrying a `MultiModalArc`, with one
  `SingleAssignment{C}` slot per mode.
"""
abstract type AbstractArcAssignment{C<:LightCommodity} end

"""
$TYPEDEF

Assignment payload for a single-mode edge.

# Fields
$TYPEDFIELDS
"""
mutable struct SingleAssignment{C<:LightCommodity} <: AbstractArcAssignment{C}
    "commodities routed across this edge"
    commodities::Vector{C}
    "bin assignments (populated only for BinPackingArcCost edges)"
    bins::Vector{Bin{C}}
    "cost of routing the stored commodities across this edge"
    cost::Float64
end

function SingleAssignment{C}() where {C<:LightCommodity}
    return SingleAssignment{C}(C[], Bin{C}[], 0.0)
end

"""
$TYPEDSIGNATURES

Commodities routed across the edge represented by `a`.
"""
commodities_of(a::SingleAssignment) = a.commodities

"""
$TYPEDSIGNATURES

Bin assignments stored on the edge represented by `a`.
"""
bins_of(a::SingleAssignment) = a.bins

"""
$TYPEDSIGNATURES

Total cost charged for the edge represented by `a`.
"""
cost_of(a::SingleAssignment) = a.cost

"""
$TYPEDEF

Assignment payload for a multi-modal edge. Each slot in `per_mode` is a
`SingleAssignment{C}` parallel to the corresponding mode in `MultiModalArc.modes`.

# Fields
$TYPEDFIELDS
"""
struct MultiAssignment{C<:LightCommodity} <: AbstractArcAssignment{C}
    "one slot per mode, parallel to `MultiModalArc.modes`"
    per_mode::Vector{SingleAssignment{C}}
end

"""
    MultiAssignment{C}(n_modes)

Pre-allocate `n_modes` empty `SingleAssignment{C}` slots, one per transport mode.
"""
function MultiAssignment{C}(n_modes::Int) where {C<:LightCommodity}
    return MultiAssignment{C}([SingleAssignment{C}() for _ in 1:n_modes])
end

"""
$TYPEDSIGNATURES

Commodities routed across the edge represented by `a` (concatenated across all modes).
"""
function commodities_of(a::MultiAssignment{C}) where {C}
    return reduce(vcat, commodities_of(s) for s in a.per_mode; init=C[])
end

"""
$TYPEDSIGNATURES

Bin assignments across all modes on the edge represented by `a`.
"""
function bins_of(a::MultiAssignment{C}) where {C}
    return reduce(vcat, bins_of(s) for s in a.per_mode; init=Bin{C}[])
end

"""
$TYPEDSIGNATURES

Total cost across all modes on the edge represented by `a`.
"""
cost_of(a::MultiAssignment) = sum(cost_of, a.per_mode; init=0.0)
