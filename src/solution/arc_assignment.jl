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
    "arc cost of routing the stored commodities across this edge"
    arc_cost::Float64
    "node cost charged at the edge's head node for the stored commodities.
    Always `0.0` when this `SingleAssignment` is a per-mode slot of a `MultiAssignment`
    (see the `MultiAssignment.node_cost` field docstring)."
    node_cost::Float64
    "set to true if `commodities` is currently in descending order by `.size`"
    sorted::Bool
    "cached `sum(c.size for c in commodities)`, maintained incrementally"
    total_size::Float64
    "true when `bins` may not reflect `commodities` (skipped repack on removal)"
    bins_dirty::Bool
end

function SingleAssignment{C}() where {C<:LightCommodity}
    return SingleAssignment{C}(C[], Bin{C}[], 0.0, 0.0, true, 0.0, false)
end

"""
$TYPEDSIGNATURES

3-arg convenience constructor for callers with `sorted=false`. `node_cost` defaults
to `0.0` (see the field docstring for the multi-modal-slot invariant).
"""
function SingleAssignment{C}(
    commodities::Vector{C}, bins::Vector{Bin{C}}, arc_cost::Float64
) where {C<:LightCommodity}
    ts = sum(c.size for c in commodities; init=0.0)
    return SingleAssignment{C}(commodities, bins, arc_cost, 0.0, false, ts, false)
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

Arc cost charged for the edge represented by `a` (excludes the head-node cost, see
[`node_cost_of`](@ref)).
"""
arc_cost_of(a::SingleAssignment) = a.arc_cost

"""
$TYPEDSIGNATURES

Head-node cost charged for the edge represented by `a`.
"""
node_cost_of(a::AbstractArcAssignment) = a.node_cost

"""
$TYPEDSIGNATURES

Total cost charged for the edge represented by `a`: [`arc_cost_of`](@ref) plus
[`node_cost_of`](@ref).
"""
cost_of(a::AbstractArcAssignment) = arc_cost_of(a) + node_cost_of(a)

"""
$TYPEDSIGNATURES

Cached sum of commodity sizes on the edge represented by `a`.
"""
total_size_of(a::SingleAssignment) = a.total_size

"""
$TYPEDSIGNATURES

The load (commodities) an [`AbstractNodeCostFunction`](@ref) is evaluated on for the
edge represented by `a`: the stored vector for a `SingleAssignment` slot, or the
materialized union across modes for a `MultiAssignment` (the node cost is charged
once, on the full multi-modal load).
"""
_node_load(a::SingleAssignment) = a.commodities

"""
$TYPEDEF

Assignment payload for a multi-modal edge. Each slot in `per_mode` is a
`SingleAssignment` parallel to the corresponding mode in the associated
`MultiModalArc.modes`.

# Fields
$TYPEDFIELDS
"""
mutable struct MultiAssignment{C<:LightCommodity} <: AbstractArcAssignment{C}
    "one slot per mode"
    per_mode::Vector{SingleAssignment{C}}
    "node cost charged once at the edge's head node, for the union of the load
    across all modes. Mode-independent (unlike `arc_cost`), so it is stored once here
    rather than on each per-mode `SingleAssignment` slot, whose own `node_cost` stays
    `0.0`."
    node_cost::Float64
end

"""
$TYPEDSIGNATURES

Pre-allocate `n_modes` empty `SingleAssignment{C}` slots, one per transport mode.
"""
function MultiAssignment{C}(n_modes::Int) where {C<:LightCommodity}
    return MultiAssignment{C}([SingleAssignment{C}() for _ in 1:n_modes], 0.0)
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

Arc cost across all modes on the edge represented by `a` (excludes the head-node
cost, which is stored once on `a.node_cost`, see [`node_cost_of`](@ref)).
"""
arc_cost_of(a::MultiAssignment) = sum(arc_cost_of, a.per_mode; init=0.0)

"""
$TYPEDSIGNATURES

Cached sum of commodity sizes across all modes on the edge represented by `a`.
"""
total_size_of(a::MultiAssignment) = sum(total_size_of, a.per_mode; init=0.0)

"""
$TYPEDSIGNATURES

The load (commodities) an [`AbstractNodeCostFunction`](@ref) is evaluated on for the
edge represented by `a`: the union of commodities across all modes, materialized into
a `Vector{C}` (the node cost is charged once, on the full multi-modal load).
"""
function _node_load(a::MultiAssignment{C}) where {C<:LightCommodity}
    return collect(C, commodities_of(a))
end

# Internal helper for counting commodities on an edge assignment, used in cost calculations.
_bin_count(a::SingleAssignment) = length(a.bins)
_bin_count(a::MultiAssignment) = sum(length(slot.bins) for slot in a.per_mode; init=0)
