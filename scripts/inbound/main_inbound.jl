using Dates
using TransportationPlanningOptimization
includet(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound

instance_name = "medium"
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

solution = greedy_heuristic(instance);
is_feasible(solution, instance; verbose=true)
cost(solution)
# solution = local_search!(solution, instance; time_limit=10);
# is_feasible(solution, instance; verbose=true)
# is_feasible(solution_2, instance; verbose=true)
# cost(solution)

lb_solution = lower_bound_filtering(instance);
filtered_instance = extract_filtered_instance(instance, lb_solution)
partial_solution = greedy_heuristic(filtered_instance);
partial_solution = local_search!(partial_solution, filtered_instance; time_limit=10);
full_solution = merge_solutions(lb_solution, partial_solution, instance, filtered_instance);
is_feasible(full_solution, instance; verbose=true)
cost(full_solution)
