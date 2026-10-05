using TransportationPlanningOptimization
using TransportationPlanningOptimization.Problems.Inbound

instance_name = "small"
instance = load_instance(RenaultInbound(), instance_name);
instance

solution = solve(instance; time_limit=30)
is_feasible(solution, instance; verbose=true)
cost(solution)
total_arc_cost(solution)
total_node_cost(solution)
solution
