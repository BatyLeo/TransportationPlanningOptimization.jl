module NetworkDesignOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using Dates: DateTime
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using Graphs: Graphs
using MetaGraphsNext: MetaGraphsNext, MetaGraph

include("commodity.jl")
include("order.jl")
include("graphs/network_node.jl")
include("graphs/network_arc.jl")
include("graphs/network_graph.jl")
include("bundle.jl")
include("instance.jl")
include("typed_instance.jl")

include("parsing/commodity.jl")

export LightCommodity
export Instance, Bundle, Order, Commodity
export NetworkNode, NetworkArc
export NetworkGraph

export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost
export TypedInstance, collect_arcs

export evaluate

end
