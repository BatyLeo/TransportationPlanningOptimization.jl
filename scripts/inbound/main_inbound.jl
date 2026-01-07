using Dates
using NetworkDesignOptimization
includet(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound

instance_name = "tiny"
# datadir = joinpath(@__DIR__, "..", "..", "data", "inbound")
datadir = joinpath(@__DIR__, "..", "..", "test", "public")
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
    nodes, arcs, commodities, Week(1), (LinearArcCost, BinPackingArcCost); wrap_time=false
);
instance

empty_sol = Solution(instance)
is_feasible(empty_sol, instance)

greedy_solution = greedy_construction(instance)
is_feasible(greedy_solution, instance)
cost(greedy_solution)
[
    [label_for(instance.travel_time_graph.graph, ee) for ee in e] for
    e in greedy_solution.bundle_paths
]

bb = [
    [("P2", 2), ("P4", 1), ("D2", 0)],
    [("O1", 4), ("P1", 2), ("P3", 1), ("D2", 0)],
    [("O2", 5), ("P2", 3), ("P3", 1), ("D1", 0)],
    [("O1", 4), ("P1", 2), ("P3", 1), ("D1", 0)],
]
using MetaGraphsNext
bundle_paths = map(bb) do path
    map(path) do node_label
        MetaGraphsNext.code_for(instance.travel_time_graph.graph, node_label)
    end
end
new_solution = Solution(bundle_paths, instance)
is_feasible(new_solution, instance)
cost(new_solution)
# @profview greedy_solution = greedy_construction(instance)

solution_2 = Solution(greedy_solution.bundle_paths, instance)
is_feasible(solution_2, instance)
cost(solution_2, instance)

write_solution_csv(joinpath(@__DIR__, "greedy_solution.csv"), greedy_solution, instance)
read_greedy_solution = read_solution_csv(
    joinpath(@__DIR__, "greedy_solution.csv"), instance
)

cost(greedy_solution)
is_feasible(greedy_solution, instance)
cost(read_greedy_solution)
is_feasible(read_greedy_solution, instance)

readable_solution = read_solution_csv(joinpath(@__DIR__, "readable_solution.csv"), instance)
cost(readable_solution)
is_feasible(readable_solution, instance)

filter(collect(edge_labels(instance.travel_time_graph.graph))) do ((id1, t1), (id2, t2))
    return contains(id1, "O") && contains(id2, "O")
end
