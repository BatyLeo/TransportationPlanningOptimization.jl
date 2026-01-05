using Dates
using NetworkDesignOptimization
includet(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound

instance_name = "small"
datadir = joinpath(@__DIR__, "..", "..", "data", "inbound")
nodes_file = joinpath(datadir, "$(instance_name)_nodes.csv")
legs_file = joinpath(datadir, "$(instance_name)_legs.csv")
commodities_file = joinpath(datadir, "$(instance_name)_commodities.csv")

(; nodes, arcs, commodities) = parse_inbound_instance(
    nodes_file, legs_file, commodities_file
);

eltype(nodes)
eltype(arcs)
eltype(commodities)

instance = build_instance(
    nodes, arcs, commodities, Week(1), (LinearArcCost, BinPackingArcCost)
);
instance

empty_sol = Solution(instance)
is_feasible(empty_sol, instance)
greedy_solution = greedy_construction(instance)
is_feasible(greedy_solution, instance)
cost(greedy_solution)
# @profview greedy_solution = greedy_construction(instance)

write_solution_csv(joinpath(@__DIR__, "greedy_solution.csv"), greedy_solution, instance)
read_greedy_solution = read_solution_csv(
    joinpath(@__DIR__, "greedy_solution.csv"), instance
)

cost(greedy_solution)
is_feasible(greedy_solution, instance)
cost(read_greedy_solution)
is_feasible(read_greedy_solution, instance)

mismatches = 0
for i in 1:bundle_count(instance)
    if greedy_solution.bundle_paths[i] != read_greedy_solution.bundle_paths[i]
        global mismatches += 1
    end
end
println("Path Mismatches: ", mismatches)

readable_solution = read_solution_csv(joinpath(@__DIR__, "readable_solution.csv"), instance)
cost(readable_solution)
is_feasible(readable_solution, instance)