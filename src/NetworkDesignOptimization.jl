module NetworkDesignOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using Dates: DateTime
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES

include("commodity.jl")
include("order.jl")
include("network_node.jl")
include("network_arc.jl")
include("bundle.jl")
include("instance.jl")
include("typed_instance.jl")

include("parsing/commodity.jl")

export FullCommodity
export Instance, Bundle, Order, Commodity, NetworkNode, NetworkArc
export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost
export TypedInstance, collect_arcs

export evaluate

end
