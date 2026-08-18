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

(; nodes, arcs, commodities) = Inbound.parse_inbound_instance(
    nodes_file, legs_file, commodities_file
);

instance = Instance(nodes, arcs, commodities, Week(1); wrap_time=true);
instance

filtering_sol = lower_bound_filtering(instance);
sub_instance = TPO.extract_filtered_instance(instance, filtering_sol)

candidates = mix_greedy_and_lower_bound(sub_instance)
sub_sol = TPO.choose_best_feasible(
    [candidates.mixed, candidates.greedy, candidates.lower_bound], sub_instance
)

local_search!(sub_sol, sub_instance; time_limit=30);

full_solution = TPO.merge_solutions(filtering_sol, sub_sol, instance, sub_instance);
is_feasible(full_solution, instance; verbose=true)
cost_with_nodes(full_solution, instance)
cost(full_solution)
full_solution
