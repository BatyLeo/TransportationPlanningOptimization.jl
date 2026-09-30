using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound

instance_name = "small"
instance = load_instance(RenaultInbound(), instance_name);
instance

full_solution = solve(instance; time_limit=30)
is_feasible(full_solution, instance; verbose=true)
cost(full_solution)
total_arc_cost(full_solution)
total_node_cost(full_solution)
full_solution
