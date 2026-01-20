using CSV
using DataFrames
using TransportationPlanningOptimization
using LinearAlgebra
using Random
using Graphs, SimpleWeightedGraphs
using Statistics
using MultivariateStats
using GLMakie
using Tyler

instance = "world"
datadir = joinpath(@__DIR__, "..", "data", "inbound")
nodes_file = joinpath(datadir, "$(instance)_nodes.csv")
legs_file = joinpath(datadir, "$(instance)_legs.csv")
commodities_file = joinpath(datadir, "$(instance)_commodities.csv")

df_nodes = DataFrame(CSV.File(nodes_file))
df_legs = DataFrame(CSV.File(legs_file))
println("Node columns: ", names(df_nodes))
println("Legs columns: ", names(df_legs))

# Loop over df_nodes and extract Node attributes
nodes_data = map(eachrow(df_nodes)) do row
    (
        point_type=Symbol(row.point_type),
        point_account=row.point_account,
        point_m3_cost=row.point_m3_cost,
        capacity=row.point_m3_capacity,
        overload_cost=row.point_overload_m3_cost,
    )
end

# Loop over df_legs and extract the two node accounts and distance value
legs_data = map(eachrow(df_legs)) do row
    (src_account=row.src_account, dst_account=row.dst_account, distance=row.distance)
end

# Create a mapping from account to node index
unique_accounts = unique([row.point_account for row in nodes_data])
n_nodes = length(unique_accounts)
account_to_idx = Dict(account => idx for (idx, account) in enumerate(unique_accounts))

println("Number of nodes: ", n_nodes)
println("Number of legs: ", length(legs_data))

# Create a weighted graph from the legs data
g = SimpleWeightedGraph(n_nodes)

# Add edges with weights (distances)
for leg in legs_data
    src_idx = account_to_idx[leg.src_account]
    dst_idx = account_to_idx[leg.dst_account]
    add_edge!(g, src_idx, dst_idx, leg.distance)
end

# Compute all shortest paths using Floyd-Warshall
shortest_paths = floyd_warshall_shortest_paths(g)

# Extract the distance matrix
shortest_distance_matrix = shortest_paths.dists

println("Shortest distance matrix computed!")
println("Matrix size: $(size(shortest_distance_matrix))")
println("Sample shortest distances (first 5x5):")
println(shortest_distance_matrix[1:min(5, n_nodes), 1:min(5, n_nodes)])

# MDS: multi-dimensional scaling
M = fit(MDS, shortest_distance_matrix; maxoutdim=2, distances=true)
Y = predict(M)
# scatter(Y[1, :], Y[2, :])

# Create vectors for different point types
point_types = [nodes_data[i].point_type for i in 1:length(nodes_data)]

# Define colors and shapes for each point type
colors = Dict(
    :supplier => :red,
    :platform => :blue,
    :plant => :green,
    :pol => :orange,
    :pod => :purple,
)
shapes = Dict(
    :supplier => :circle,
    :platform => :square,
    :plant => :diamond,
    :pol => :utriangle,
    :pod => :dtriangle,
)

# Create the plot with different colors and shapes
fig = Figure();
ax = Axis(fig[1, 1]);

for point_type in [:supplier, :platform, :plant, :pol, :pod]
    indices = findall(x -> x == point_type, point_types)
    if !isempty(indices)
        GLMakie.scatter!(
            ax,
            Y[1, indices],
            Y[2, indices];
            color=colors[point_type],
            marker=shapes[point_type],
            label=string(point_type),
            markersize=20,
        )
    end
end

# Add arcs (edges) to the plot
# for leg in legs_data
#     src_idx = account_to_idx[leg.src_account]
#     dst_idx = account_to_idx[leg.dst_account]

#     lines!(
#         ax,
#         [Y[1, src_idx], Y[1, dst_idx]],
#         [Y[2, src_idx], Y[2, dst_idx]],
#         color = :gray,
#         alpha = 0.3,
#         linewidth = 1,
#     )
# end

axislegend(ax)
display(fig)
