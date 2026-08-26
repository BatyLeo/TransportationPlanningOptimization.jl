"""
$TYPEDEF

Abstract supertype for strategies that decide how a bundle's commodities are
distributed across the modes of a [`MultiModalArc`](@ref) during greedy
insertion. Concrete subtypes:
- [`CheapestMode`](@ref) places each insertion entirely on the cheapest mode
  whose remaining capacity can absorb it.
- [`FillThenSpillMode`](@ref) fills the cheapest mode up to its capacity, then
  spills overflow to the next-cheapest mode on the same edge.

New strategies are added as additional subtypes plus the matching methods on
`_edge_incremental_cost` and `_add_order_to_assignment!`.
"""
abstract type AbstractModeSelector end

"""
$TYPEDEF

Mode-selection strategy that places the insertion entirely on the cheapest mode
whose remaining capacity can absorb the load. Modes that would overflow are
skipped. An edge whose every mode would overflow is treated as infeasible (Inf
cost) during Dijkstra, and the placement path throws `ArgumentError` if reached.
"""
struct CheapestMode <: AbstractModeSelector end

"""
$TYPEDEF

Mode-selection strategy that fills the cheapest mode up to its capacity, then
spills overflow to the next-cheapest mode on the same edge, and so on. If the
combined capacity across all modes on an edge is below the load, the edge is
treated as infeasible (Inf cost) during Dijkstra, and the placement path throws
`ArgumentError` if reached.
"""
struct FillThenSpillMode <: AbstractModeSelector end
