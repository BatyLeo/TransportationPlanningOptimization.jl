using TransportationPlanningOptimization
includet("Outbound.jl")
using .Outbound

using DataFrames
using CSV
using Dates

# Preprocessing
outbound_data_dir = joinpath(@__DIR__, "..", "..", "data", "outbound")
raw_data_file = joinpath(outbound_data_dir, "raw", "HexData.csv")
data_dir = joinpath(outbound_data_dir, "parsed")
preprocessing_outbound_data(raw_data_file, data_dir; overwrite=false)

node_file = joinpath(data_dir, "parsed_nodes.csv")
leg_file = joinpath(data_dir, "parsed_legs.csv")
commodity_file = joinpath(data_dir, "parsed_volumes.csv")
model_file = joinpath(data_dir, "parsed_models.csv")
load_factor_file = joinpath(data_dir, "load_factor_min_estimated.csv")

(; nodes, arcs, commodities) = parse_outbound_instance(
    node_file,
    leg_file,
    commodity_file,
    model_file,
    load_factor_file;
    max_delivery_time=Week(36),
);

instance = Instance(
    nodes,
    arcs,
    commodities,
    Week(1000);
    group_by=commodity -> (commodity.info.model, commodity.info.is_BTS),
    wrap_time=false,
);
instance

empty_sol = Solution(instance)
is_feasible(empty_sol, instance; verbose=true)

greedy_solution = greedy_construction(instance)
is_feasible(greedy_solution, instance; verbose=true)
cost(greedy_solution)
