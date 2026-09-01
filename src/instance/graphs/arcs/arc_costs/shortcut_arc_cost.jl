"""
$TYPEDEF

Cost function for a shortcut arc, always returning zero.
"""
struct ShortcutArcCost <: AbstractArcCostFunction end

"""
$TYPEDSIGNATURES
"""
evaluate(::ShortcutArcCost, ::Vector{<:LightCommodity}; presorted::Bool=false) = 0.0
