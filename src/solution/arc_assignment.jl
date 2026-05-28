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
    "true iff `commodities` is currently in descending order by `.size`; lets bin-packing skip its internal sort on the LS hot path"
    sorted::Bool
end

function SingleAssignment{C}() where {C<:LightCommodity}
    # Empty vector is trivially sorted.
    return SingleAssignment{C}(C[], Bin{C}[], 0.0, true)
end

# 3-arg convenience constructor for callers (tests, ad-hoc construction) that
# do not know or maintain the sort order. Defaults `sorted=false` so the next
# FFD call sorts before using.
function SingleAssignment{C}(
    commodities::Vector{C}, bins::Vector{Bin{C}}, cost::Float64
) where {C<:LightCommodity}
    return SingleAssignment{C}(commodities, bins, cost, false)
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
mutable struct MultiAssignment{C<:LightCommodity} <: AbstractArcAssignment{C}
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

Lazy iterator over commodities routed across the edge represented by `a`,
flattened across all modes. Use `collect` to materialize into a `Vector`.
"""
function commodities_of(a::MultiAssignment)
    return Iterators.flatten(slot.commodities for slot in a.per_mode)
end

"""
$TYPEDSIGNATURES

Lazy iterator over bin assignments across all modes on the edge represented by `a`.
Use `collect` to materialize into a `Vector`.
"""
function bins_of(a::MultiAssignment)
    return Iterators.flatten(slot.bins for slot in a.per_mode)
end

"""
$TYPEDSIGNATURES

Total cost across all modes on the edge represented by `a`.
"""
cost_of(a::MultiAssignment) = sum(cost_of, a.per_mode; init=0.0)
