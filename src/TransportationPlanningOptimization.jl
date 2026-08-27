module TransportationPlanningOptimization

using CSV: CSV
using DataFrames: DataFrame, names
using DataStructures: DataStructures
using Dates: Dates, DateTime, Period
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using Graphs: Graphs
using MetaGraphsNext: MetaGraphsNext, MetaGraph, haskey, code_for, label_for
using OhMyThreads: OhMyThreads, @tasks, @set, index_chunks
using ProgressMeter: @showprogress
using SparseArrays: SparseArrays, SparseMatrixCSC, sparse

include("constants.jl")
include("utils.jl")

include("instance/commodity.jl")
include("instance/order.jl")
include("instance/bundle.jl")

include("instance/graphs/arcs/arc_costs/bin_packing/bin.jl")
include("instance/graphs/arcs/arc_costs/bin_packing/ffd.jl")
include("instance/graphs/arcs/arc_costs/bin_packing/bfd.jl")

include("instance/graphs/nodes/node_cost.jl")
include("instance/graphs/nodes/network_node.jl")
include("instance/graphs/arcs/arc_costs/abstract_arc_cost.jl")
include("instance/graphs/arcs/arc_costs/shortcut_arc_cost.jl")
include("instance/graphs/arcs/arc_costs/linear_arc_cost.jl")
include("instance/graphs/arcs/arc_costs/bin_packing_arc_cost.jl")
include("instance/graphs/arcs/arc_costs/sum_arc_cost.jl")
include("instance/graphs/arcs/network_arc.jl")

include("instance/input/commodity.jl")
include("instance/input/arc.jl")
include("instance/input/node.jl")

include("instance/graphs/network_graph.jl")
include("instance/graphs/time_space_graph.jl")
include("instance/graphs/travel_time_graph.jl")
include("instance/index_cache.jl")

include("instance/instance.jl")

include("solution/mode_selector.jl")
include("solution/arc_assignment.jl")
include("solution/assignment_operations.jl")
include("solution/solution.jl")
include("solution/path_operations.jl")
include("solution/feasibility.jl")
include("solution/parsing.jl")

include("algorithms/shortest_path.jl")
include("algorithms/cost/edge_cost.jl")
include("algorithms/cost/cost_matrix_update.jl")
include("algorithms/greedy_heuristic.jl")
include("algorithms/lower_bound.jl")
include("algorithms/mix_start.jl")
include("algorithms/instance_extraction.jl")
include("algorithms/merge_solutions.jl")

include("algorithms/local_search/assignment_snapshot.jl")
include("algorithms/local_search/bin_repacking.jl")
include("algorithms/local_search/bundle_reinsertion.jl")
include("algorithms/local_search/two_node_consolidation.jl")
include("algorithms/local_search/local_search.jl")
include("algorithms/solve.jl")

include("algorithms/ils/perturbation.jl")
include("algorithms/ils/config.jl")
include("algorithms/ils/snapshot.jl")
include("algorithms/ils/large_local_search.jl")
include("algorithms/ils/slope_scaling.jl")
include("algorithms/ils/iterated_local_search.jl")

# Types
export LightCommodity, Commodity, Order, Bundle, Instance
export NetworkNode, AbstractNetworkArc, NetworkArc, MultiModalArc, Arc
export AbstractNodeCostFunction, NoNodeCost
export AbstractArcCostFunction, LinearArcCost, BinPackingArcCost, SumArcCost
export NetworkGraph, TimeSpaceGraph, TravelTimeGraph
export Solution
export AbstractModeSelector, CheapestMode, FillThenSpillMode

# Instance queries
export bundle_count, order_count, commodity_count, total_size, max_pack_size
export time_horizon

# Cost function interface
export evaluate

# Solution interface
export is_feasible, cost, cost_with_nodes
export commodities_of, bins_of, cost_of, total_size_of
export write_solution_csv, read_solution_csv

# Algorithms
export greedy_heuristic, lower_bound, lower_bound_filtering
export mix_greedy_heuristic, local_search!, solve_filtered
export LocalSearchResult

# ILS framework
export AbstractPerturbation, perturbate!
export ILSConfig, ILSResult
export snapshot_solution, restore_solution!
export large_local_search!
export slope_scaling_update!
export iterated_local_search!

"""
    gurobi_optimizer()

Return a JuMP-compatible Gurobi optimizer instance using a cached `Gurobi.Env`.
Requires `Gurobi.jl` to be loaded (activates `TransportationPlanningOptimizationGurobiExt`).

Pass as a factory to JuMP: `Model(gurobi_optimizer)`.
"""
function gurobi_optimizer end

export gurobi_optimizer

end
