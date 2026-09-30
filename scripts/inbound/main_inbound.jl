using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound

instance_name = "small"
instance = load_instance(RenaultInbound(), instance_name);
instance

filtering_sol = lower_bound_filtering(instance);
sub_instance = TPO.extract_filtered_instance(instance, filtering_sol)
start = TPO.preload_filtered_bundles(filtering_sol, instance, sub_instance)

sub_sol = mix_greedy_heuristic(sub_instance; start)

res = local_search!(sub_sol, sub_instance; time_limit=30);

full_solution = TPO.merge_solutions(filtering_sol, sub_sol, instance, sub_instance);
is_feasible(full_solution, instance; verbose=true)
cost(full_solution)
total_arc_cost(full_solution)
total_node_cost(full_solution)
full_solution
