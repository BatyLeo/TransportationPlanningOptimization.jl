using Dates
using TransportationPlanningOptimization
includet(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound

instance_name = "small"
# datadir = joinpath(@__DIR__, "..", "..", "data", "inbound")
datadir = joinpath(@__DIR__, "..", "..", "test", "public")
nodes_file = joinpath(datadir, "$(instance_name)_nodes.csv")
legs_file = joinpath(datadir, "$(instance_name)_legs.csv")
commodities_file = joinpath(datadir, "$(instance_name)_commodities.csv")

(; nodes, arcs, commodities) = parse_inbound_instance(
    nodes_file, legs_file, commodities_file
);

instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true);
instance

greedy_solution = greedy_heuristic(instance);
is_feasible(greedy_solution, instance; verbose=true)
cost(greedy_solution)
