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
