# ideally, non decreasing with size
"""
$TYPEDEF

Abstract base type for cost functions defined on network arcs.
Concrete subtypes determine how load/size on an arc is translated into a financial or performance cost.
"""
abstract type AbstractArcCostFunction end

"""
$TYPEDEF

Abstract supertype for arcs in the spatial network graph.

Concrete subtypes:
- `NetworkArc` (single transport mode, the common case)
- `MultiModalArc` (a leg traversable by several transport modes, e.g., truck and train sharing the same physical leg)

Methods that need to act on either form should dispatch on this supertype.
"""
abstract type AbstractNetworkArc end

"""
$TYPEDEF

A linear cost function where the cost is directly proportional to the total size/load on the arc.

# Fields
$TYPEDFIELDS
"""
struct LinearArcCost <: AbstractArcCostFunction
    "Unit cost per unit of size (e.g. m³, kg, etc.)"
    cost_per_unit_size::Float64
end

"""
$TYPEDEF

A bin-packing (or step) cost function. A fixed cost is incurred for each bin/truck needed.
# Fields
$TYPEDFIELDS
"""
struct BinPackingArcCost <: AbstractArcCostFunction
    "Fixed cost for each bin used (e.g., cost per truck)"
    cost_per_bin::Float64
    "Capacity of a single bin/truck"
    bin_capacity::Int
end
# algebraic data types
# multi criteria
struct VectorPackingArcCost <: AbstractArcCostFunction end

# grid: discretized km, m3, kg -> cost per m3
struct GridLinearArcCost <: AbstractArcCostFunction end

# cout arc de douane (qui passe par un point de douane)

"""
$TYPEDEF

Representation of a single-mode arc in the network graph.

# Fields
$TYPEDFIELDS
"""
@kwdef struct NetworkArc{C<:AbstractArcCostFunction,K} <: AbstractNetworkArc
    "travel time in number of discrete time steps (0 if less than the time discretization step)"
    travel_time_steps::Int
    "capacity of the arc (in size units)"
    capacity::Int = typemax(Int)
    "cost function associated with the arc"
    cost::C
    "additional information associated with the arc"
    info::K = nothing
end

"""
$TYPEDEF

A leg traversable by several transport modes. Each mode is its own `NetworkArc` with its
own `travel_time_steps`, `capacity`, and `cost` function.

When projected into the time-expanded graphs (`TimeSpaceGraph`, `TravelTimeGraph`), modes
are grouped by `travel_time_steps`:
- Modes with distinct transit times land at different timed vertices and each emit a plain
  `NetworkArc` edge (case 1).
- Modes sharing the same transit time collapse to a single `MultiModalArc` edge per timed
  pair, carrying just that subset of modes (case 2). The greedy heuristic's
  [`CheapestMode`](@ref) selector picks the cheapest mode whose remaining capacity can
  absorb the new commodities. Modes that would overflow are skipped, and an edge whose
  every mode would overflow is treated as infeasible (Inf cost) during Dijkstra. See the
  `mode_selector` keyword on [`greedy_heuristic`](@ref) for the alternative
  [`FillThenSpillMode`](@ref) strategy that splits an order across modes.

!!! note
    The type parameter `T` is concrete only when every mode shares the same
    `NetworkArc{C,K}` parameterisation. Mixing modes with different cost functions
    (for example one `LinearArcCost` and one `BinPackingArcCost`) falls back to
    `T = NetworkArc` (abstract), which removes dispatch specialisation on the inner
    cost type at the call sites that read mode data. Behaviour is unchanged, but
    performance-sensitive instances should keep mode cost functions homogeneous.

# Fields
$TYPEDFIELDS
"""
struct MultiModalArc{T<:NetworkArc} <: AbstractNetworkArc
    "the modes available on this leg (one `NetworkArc` per mode)"
    modes::Vector{T}
end

function Base.show(io::IO, arc::MultiModalArc)
    return print(io, "MultiModalArc(", length(arc.modes), " modes)")
end

"""
A small marker cost function used to represent shortcut / wait arcs.
This makes dispatch and checks explicit instead of relying on numeric values.
"""
struct ShortcutArcCost <: AbstractArcCostFunction end

"""
A predefined `NetworkArc` representing a zero-cost, zero-duration transition (e.g., waiting at a node).
"""
const SHORTCUT_ARC = NetworkArc(; travel_time_steps=0, cost=ShortcutArcCost())

function Base.show(io::IO, arc::NetworkArc)
    return print(
        io,
        "NetworkArc(",
        "capacity=$(arc.capacity == typemax(Int) ? "∞" : string(arc.capacity)), ",
        "cost=$(arc.cost), ",
        "info=$(arc.info)",
        ")",
    )
end

# Conversion constructor to widen the cost type parameter
# This allows automatic conversion to union types
function NetworkArc{C,K}(arc::NetworkArc) where {C<:AbstractArcCostFunction,K}
    return NetworkArc{C,K}(;
        capacity=arc.capacity,
        travel_time=arc.travel_time_steps,
        cost=arc.cost,
        info=arc.info,
    )
end

"""
$TYPEDSIGNATURES

Return the travel duration (in discrete steps) associated with the arc.
"""
travel_time_steps(arc::NetworkArc) = arc.travel_time_steps

"""
$TYPEDSIGNATURES

Evaluate the cost of transporting a list of commodities on an arc with a linear cost function.
The cost is proportional to the total size of all commodities.
"""
function evaluate(
    arc_f::LinearArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    total_size = sum(c.size for c in commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_size
end

"""
$TYPEDSIGNATURES

Evaluate the cost of transporting a list of commodities on an arc with a bin-packing cost function.
The cost is based on the number of bins (trucks) needed to transport all commodities.
Uses the First-Fit Decreasing (FFD) heuristic to determine bin assignments and count.
"""
function evaluate(
    arc_f::BinPackingArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    # tentative_bin_count returns the same `length` as compute_bin_assignments
    # without allocating Bin objects, and honors the presorted hint.
    return arc_f.cost_per_bin * tentative_bin_count(arc_f, commodities; presorted)
end

"""
$TYPEDSIGNATURES

Evaluate the cost of a shortcut (wait) arc: always zero.
"""
evaluate(::ShortcutArcCost, ::Vector{<:LightCommodity}; presorted::Bool=false) = 0.0

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
