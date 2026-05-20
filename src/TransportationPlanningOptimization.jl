module TransportationPlanningOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using Dates: Dates, DateTime, Period
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using Graphs: Graphs
using MetaGraphsNext: MetaGraphsNext, MetaGraph, haskey, code_for, label_for
using ProgressMeter: @showprogress
using SparseArrays: SparseMatrixCSC, sparse

include("utils.jl")

include("instance/commodity.jl")
include("instance/order.jl")
include("instance/bundle.jl")

include("instance/graphs/network_node.jl")
include("instance/graphs/network_arc.jl")
include("instance/bin.jl")

include("instance/parsing/commodity.jl")
include("instance/parsing/arc.jl")

include("instance/graphs/network_graph.jl")
include("instance/graphs/time_space_graph.jl")
include("instance/graphs/travel_time_graph.jl")

include("instance/instance.jl")

include("solution/arc_assignment.jl")
include("algorithms/mode_selector.jl")
include("solution/solution.jl")
include("solution/parsing.jl")
include("algorithms/greedy_insertion.jl")

export LightCommodity
export Instance, Bundle, Order, Commodity
export bundle_count, order_count, commodity_count, total_size
export write_solution_csv, read_solution_csv
export NetworkNode, AbstractNetworkArc, NetworkArc, MultiModalArc, Arc
export NetworkGraph

export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost
export Bin
export collect_arcs

export evaluate

export TimeSpaceGraph, TravelTimeGraph

export time_horizon

export Solution, is_feasible, cost, add_bundle_path!
export AbstractArcAssignment, SingleAssignment, MultiAssignment
export commodities_of, bins_of, cost_of
export AbstractModeSelector, CheapestMode, FillThenSpillMode
export greedy_heuristic

"""
    gurobi_optimizer()

Return a JuMP-compatible Gurobi optimizer instance using a cached `Gurobi.Env`.
Requires `Gurobi.jl` to be loaded (activates
`TransportationPlanningOptimizationGurobiExt`).

Pass as a factory to JuMP: `Model(gurobi_optimizer)`.
"""
function gurobi_optimizer end

export gurobi_optimizer

end
