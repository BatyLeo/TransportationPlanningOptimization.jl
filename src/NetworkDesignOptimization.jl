module NetworkDesignOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using Dates: Dates, DateTime, Period
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using Graphs: Graphs
using MetaGraphsNext: MetaGraphsNext, MetaGraph, haskey

include("commodity.jl")
include("order.jl")
include("bundle.jl")

include("graphs/network_node.jl")
include("graphs/network_arc.jl")

include("parsing/commodity.jl")
include("parsing/arc.jl")

include("graphs/network_graph.jl")
include("graphs/time_space_graph.jl")
include("graphs/travel_time_graph.jl")

include("instance.jl")

include("time_utils.jl")

export LightCommodity
export Instance, Bundle, Order, Commodity
export build_instance
export NetworkNode, NetworkArc, Arc
export NetworkGraph

export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost
export collect_arcs

export evaluate

end
