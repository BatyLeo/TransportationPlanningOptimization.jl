"""
$TYPEDEF

Cost function for a shortcut arc, always returning zero.
"""
struct ShortcutArcCost <: AbstractArcCostFunction end

"""
$TYPEDSIGNATURES

Evaluate the cost of a shortcut (wait) arc: always zero.
"""
evaluate(::ShortcutArcCost, ::Vector{<:LightCommodity}; presorted::Bool=false) = 0.0
