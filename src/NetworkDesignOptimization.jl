module NetworkDesignOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using Dates: Dates, DateTime, Period
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using Graphs: Graphs
using MetaGraphsNext: MetaGraphsNext, MetaGraph, haskey, code_for, label_for
using SparseArrays: SparseMatrixCSC, sparse

include("utils.jl")

include("instance/commodity.jl")
include("instance/order.jl")
include("instance/bundle.jl")

include("instance/graphs/network_node.jl")
include("instance/graphs/network_arc.jl")

include("instance/parsing/commodity.jl")
include("instance/parsing/arc.jl")

include("instance/graphs/network_graph.jl")
include("instance/graphs/time_space_graph.jl")
include("instance/graphs/travel_time_graph.jl")

include("instance/instance.jl")

include("solution/solution.jl")

export LightCommodity
export Instance, Bundle, Order, Commodity
export build_instance
export NetworkNode, NetworkArc, Arc
export NetworkGraph

export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost
export collect_arcs

export evaluate

export TimeSpaceGraph, TravelTimeGraph

export time_horizon

export Solution, is_feasible, cost

end
