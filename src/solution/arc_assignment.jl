"""
$TYPEDEF

Per-edge assignment stored in `Solution.assignments`. Concrete subtypes:
- `SingleAssignment{C}` for edges carrying a `NetworkArc`.
- `MultiAssignment{C}` for edges carrying a `MultiModalArc`, with one
  `SingleAssignment{C}` slot per mode.
"""
abstract type AbstractArcAssignment{C<:LightCommodity} end

"""
$TYPEDEF

Assignment for a single-mode edge.

# Fields
$TYPEDFIELDS
"""
mutable struct SingleAssignment{C<:LightCommodity} <: AbstractArcAssignment{C}
    "commodities routed across this edge"
    commodities::Vector{C}
    "bin assignments (populated only for `BinPackingArcCost` edges)"
    bins::Vector{Bin{C}}
    "cost of routing the stored commodities across this edge"
    cost::Float64
    "set to true if `commodities` is currently in descending order by `.size`"
    sorted::Bool
    "cached `sum(c.size for c in commodities)`, maintained incrementally"
    total_size::Float64
    "true when `bins` may not reflect `commodities` (skipped repack on removal)"
    bins_dirty::Bool
end

function SingleAssignment{C}() where {C<:LightCommodity}
    return SingleAssignment{C}(C[], Bin{C}[], 0.0, true, 0.0, false)
end

"""
$TYPEDSIGNATURES

3-arg convenience constructor for callers with `sorted=false`.
"""
function SingleAssignment{C}(
    commodities::Vector{C}, bins::Vector{Bin{C}}, cost::Float64
) where {C<:LightCommodity}
    ts = sum(c.size for c in commodities; init=0.0)
    return SingleAssignment{C}(commodities, bins, cost, false, ts, false)
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
$TYPEDSIGNATURES

Cached sum of commodity sizes on the edge represented by `a`.
"""
total_size_of(a::SingleAssignment) = a.total_size

"""
$TYPEDEF

Assignment payload for a multi-modal edge. Each slot in `per_mode` is a
`SingleAssignment` parallel to the corresponding mode in the associated
`MultiModalArc.modes`.

# Fields
$TYPEDFIELDS
"""
struct MultiAssignment{C<:LightCommodity} <: AbstractArcAssignment{C}
    "one slot per mode"
    per_mode::Vector{SingleAssignment{C}}
end

"""
$TYPEDSIGNATURES

Pre-allocate `n_modes` empty `SingleAssignment{C}` slots, one per transport mode.
"""
function MultiAssignment{C}(n_modes::Int) where {C<:LightCommodity}
    return MultiAssignment{C}([SingleAssignment{C}() for _ in 1:n_modes])
end

"""
$TYPEDSIGNATURES

Lazy iterator over all commodities routed across the edge represented by `a`,
flattened across all modes. Use `collect` to materialize into a `Vector`.
"""
function commodities_of(a::MultiAssignment)
    return Iterators.flatten(slot.commodities for slot in a.per_mode)
end

"""
$TYPEDSIGNATURES

Lazy iterator over all bin assignments across all modes on the edge represented by `a`.
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

"""
$TYPEDSIGNATURES

Cached sum of commodity sizes across all modes on the edge represented by `a`.
"""
total_size_of(a::MultiAssignment) = sum(total_size_of, a.per_mode; init=0.0)

# Internal helper for counting commodities on an edge assignment, used in cost calculations.
_bin_count(a::SingleAssignment) = length(a.bins)
_bin_count(a::MultiAssignment) = sum(length(slot.bins) for slot in a.per_mode; init=0)
