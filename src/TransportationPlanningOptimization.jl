module TransportationPlanningOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using Dates: Dates, DateTime, Period
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using Graphs: Graphs
using MetaGraphsNext: MetaGraphsNext, MetaGraph, haskey, code_for, label_for
using ProgressMeter: @showprogress
using SparseArrays: SparseArrays, SparseMatrixCSC, sparse

include("utils.jl")

include("instance/commodity.jl")
include("instance/order.jl")
include("instance/bundle.jl")

include("instance/graphs/node_cost.jl")
include("instance/graphs/network_node.jl")
include("instance/graphs/network_arc.jl")
include("instance/graphs/sum_arc_cost.jl")
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

include("algorithms/cost_matrix_update.jl")
include("algorithms/greedy_heuristic.jl")
include("algorithms/lower_bound.jl")
include("algorithms/mix_start.jl")
include("algorithms/instance_extraction.jl")
include("algorithms/merge_solutions.jl")
include("algorithms/local_search.jl")
include("algorithms/two_node_consolidation.jl")
include("algorithms/solve.jl")

export LightCommodity
export Instance, Bundle, Order, Commodity
export bundle_count, order_count, commodity_count, total_size, max_pack_size
export write_solution_csv, read_solution_csv
export NetworkNode, AbstractNetworkArc, NetworkArc, MultiModalArc, Arc
export AbstractNodeCostFunction, NoNodeCost
export NetworkGraph

export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost, SumArcCost
export Bin, tentative_bin_count, tentative_best_fit_count, compute_bin_assignments_bfd
export collect_arcs

export evaluate

export TimeSpaceGraph, TravelTimeGraph

export time_horizon

export Solution, is_feasible, cost, cost_with_nodes, add_bundle_path!, remove_bundle_path!
export AbstractArcAssignment, SingleAssignment, MultiAssignment
export commodities_of, bins_of, cost_of
export AbstractModeSelector, CheapestMode, FillThenSpillMode
export greedy_heuristic, lower_bound, lower_bound!
export lower_bound_filtering, lower_bound_filtering!
export mix_greedy_and_lower_bound, choose_best_feasible
export solve_filtered
export extract_filtered_instance
export merge_solutions
export bin_packing_improvement!, bundle_reinsertion_improvement!, local_search!
export two_node_common_incremental!, loop_two_nodes!

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
