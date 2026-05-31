"""
$TYPEDEF

Abstract supertype for arcs in the spatial network graph.

Concrete subtypes:
- `NetworkArc`: single transport mode, the common case
- `MultiModalArc`: a leg traversable by multiple transport modes
"""
abstract type AbstractNetworkArc end

"""
$TYPEDEF

Representation of a single-mode arc in the network graph.

# Fields
$TYPEDFIELDS
"""
@kwdef struct NetworkArc{C<:AbstractArcCostFunction,K} <: AbstractNetworkArc
    "travel time in number of discrete time steps (0 if less than time discretization unit)"
    travel_time_steps::Int
    "capacity of the arc (in size units)"
    capacity::Int = typemax(Int)
    "cost function associated with the arc"
    cost::C
    "additional information associated with the arc"
    info::K = nothing
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

"""
$TYPEDSIGNATURES

Return the travel duration (in discrete steps) associated with the arc.
"""
travel_time_steps(arc::NetworkArc) = arc.travel_time_steps

"""
$TYPEDEF

A leg traversable by multiple transport modes. Each mode is its own `NetworkArc` with its
own `travel_time_steps`, `capacity`, and `cost` function.

When projected into the time-expanded graphs (`TimeSpaceGraph`, `TravelTimeGraph`), modes
are grouped by `travel_time_steps`:
- Modes with distinct transit times land at different timed vertices and each emit a plain
`NetworkArc` edge.
- Modes sharing the same transit time collapse to a single `MultiModalArc` edge per timed
pair, carrying just that subset of modes. The greedy heuristic's [`CheapestMode`](@ref)
selector picks the cheapest mode whose remaining capacity can absorb the new commodities.
Modes that would overflow are skipped, and an edge whose every mode would overflow is
treated as infeasible (Inf cost) during Dijkstra. See the `mode_selector` keyword on
[`greedy_heuristic`](@ref) for the alternative [`FillThenSpillMode`](@ref) strategy that
splits an order across modes.

!!! note
    When modes share the same `NetworkArc{C,K}` parameterisation, `T` is that
    concrete type. When modes differ, the constructor narrows `T` to the small
    `Union` of the concrete types present, rather than falling back to the abstract
    `NetworkArc` join.

# Fields
$TYPEDFIELDS
"""
struct MultiModalArc{T<:NetworkArc} <: AbstractNetworkArc
    "the modes available on this leg (one `NetworkArc` per mode)"
    modes::Vector{T}

    # Narrow `T` to the small `Union` of the concrete mode types when modes are
    # heterogeneous, passthrough when already concrete.
    function MultiModalArc(modes::Vector{S}) where {S<:NetworkArc}
        isconcretetype(S) && return new{S}(modes)
        U = Union{map(typeof, modes)...}
        return new{U}(convert(Vector{U}, modes))
    end
end

function Base.show(io::IO, arc::MultiModalArc)
    return print(io, "MultiModalArc(", length(arc.modes), " modes)")
end
