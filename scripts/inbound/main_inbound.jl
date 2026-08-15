using Dates
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
includet(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound

instance_name = "small"
datadir = joinpath(@__DIR__, "..", "..", "data", "inbound")
# datadir = joinpath(@__DIR__, "..", "..", "test", "public")
nodes_file = joinpath(datadir, "$(instance_name)_nodes.csv")
legs_file = joinpath(datadir, "$(instance_name)_legs.csv")
commodities_file = joinpath(datadir, "$(instance_name)_commodities.csv")

(; nodes, arcs, commodities) = parse_inbound_instance(
    nodes_file, legs_file, commodities_file
);

instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true);
instance

lb_solution = lower_bound_filtering(instance);
filtered_instance = TPO.extract_filtered_instance(instance, lb_solution)
partial_solution = greedy_heuristic(filtered_instance);
local_search!(partial_solution, filtered_instance; time_limit=30);
full_solution = TPO.merge_solutions(
    lb_solution, partial_solution, instance, filtered_instance
);
is_feasible(full_solution, instance; verbose=true)
cost(full_solution)
full_solution
