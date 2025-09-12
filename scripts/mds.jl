using Random
using Distances
using LinearAlgebra
using Plots

using MultivariateStats

# Step 1: Generate random 2D points
Random.seed!(1234)
n_points = 10
X_original = randn(n_points, 2)  # rows are 2D points

# Step 2: Compute pairwise Euclidean distance matrix
D = pairwise(Euclidean(), X_original', dims = 2)

# Step 3: Convert distance matrix to Gram matrix
function distance_to_gram(D::Matrix{Float64})
    n = size(D, 1)
    J = I - ones(n, n) / n
    B = -0.5 * J * (D .^ 2) * J
    return B
end

B = distance_to_gram(D)

# Step 4: Eigen decomposition
eigvals_raw, eigvecs_raw = eigen(Symmetric(B))

# Step 5: Take the two largest eigenvalues
idx = sortperm(eigvals_raw, rev = true)[1:2]
eigvals = eigvals_raw[idx]
eigvecs = eigvecs_raw[:, idx]

# Step 6: Reconstruct coordinates
X_recovered = eigvecs * Diagonal(sqrt.(abs.(eigvals)))

# Step 7: Assign unique colors to each point
colors = distinguishable_colors(n_points)

# MDS: multi-dimensional scaling
M = fit(MDS, D; maxoutdim = 2, distances = true)
Y = predict(M)

# Step 8: Plot original and recovered with same colors
p1 = scatter(
    X_original[:, 1],
    X_original[:, 2],
    label = "",
    title = "Original Points",
    xlabel = "X",
    ylabel = "Y",
    color = colors,
    marker = (:circle, 8),
    legend = false,
    aspect_ratio = :equal,
)

p2 = scatter(
    X_recovered[:, 1],
    X_recovered[:, 2],
    label = "",
    title = "Recovered via MDS",
    xlabel = "X",
    ylabel = "Y",
    color = colors,
    marker = (:square, 8),
    legend = false,
    aspect_ratio = :equal,
)

p3 = scatter(
    Y[:, 1],
    Y[:, 2],
    label = "",
    title = "Recovered via MultivariateStats MDS",
    xlabel = "X",
    ylabel = "Y",
    color = colors,
    marker = (:diamond, 8),
    legend = false,
    aspect_ratio = :equal,
)

# Step 9: Show side-by-side
plot(p1, p2, p3, layout = (1, 3), size = (900, 400))
