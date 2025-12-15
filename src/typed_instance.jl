# """
#     TypedInstance{CostUnion, InfoUnion}

# A type-stable container for network design instances with heterogeneous arc cost functions.
# This struct automatically handles type stability when you have multiple cost function types.

# # Type Parameters
# - `CostUnion`: A Union type of all cost functions used (e.g., `Union{LinearArcCost, BinPackingArcCost}`)
# - `InfoUnion`: A Union type of all info types used

# # Example
# ```julia
# # Define your cost types
# const MyCostTypes = Union{LinearArcCost, BinPackingArcCost}

# # Create instance (arcs will be automatically converted)
# instance = TypedInstance{MyCostTypes}(nodes, arcs)

# # Access type-stable arcs
# for arc in instance.arcs
#     cost = evaluate(arc.cost)  # Fully type-stable!
# end
# ```
# """
# struct TypedInstance{CostUnion<:Union,K}
#     nodes::Vector{NetworkNode}
#     arcs::Vector{NetworkArc{CostUnion,K}}
#     commodities::Vector  # Can be extended similarly

#     function TypedInstance{CostUnion}(nodes, arcs, commodities=[]) where {CostUnion<:Union}
#         # Automatically convert arcs to the correct type
#         typed_arcs = collect_arcs(CostUnion, arcs)
#         K = eltype(typed_arcs).parameters[2]
#         return new{CostUnion,K}(nodes, typed_arcs, commodities)
#     end
# end

# # Convenience constructor that infers the union from a tuple of types
# function TypedInstance(cost_types::Tuple, nodes, arcs, commodities=[])
#     CostUnion = Union{cost_types...}
#     return TypedInstance{CostUnion}(nodes, arcs, commodities)
# end
