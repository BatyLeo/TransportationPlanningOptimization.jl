module NetworkDesignOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using Dates: Dates, DateTime, Period
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using Graphs: Graphs
using MetaGraphsNext: MetaGraphsNext, MetaGraph

include("parsing/commodity.jl")
include("commodity.jl")
include("order.jl")
include("graphs/network_node.jl")
include("graphs/network_arc.jl")
include("graphs/network_graph.jl")
include("bundle.jl")
include("instance.jl")
include("typed_instance.jl")

include("time_utils.jl")

export LightCommodity
export Instance, Bundle, Order, Commodity
export build_instance
export NetworkNode, NetworkArc
export NetworkGraph

export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost
export collect_arcs

export evaluate

end
