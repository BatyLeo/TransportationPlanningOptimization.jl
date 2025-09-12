using CSV, DataFrames, GLMakie

"""
Load and visualize nodes from the parsed CSV file using GLMakie
"""
function visualize_nodes_map()
    # Load the parsed nodes data
    data_dir = joinpath(@__DIR__, "..", "data", "outbound", "parsed")
    nodes_file = joinpath(data_dir, "parsed_nodes.csv")

    println("Loading nodes data from: $nodes_file")
    nodes_df = CSV.read(nodes_file, DataFrame)

    println("Loaded $(nrow(nodes_df)) nodes")

    # Filter out nodes with zero coordinates (likely invalid)
    valid_nodes = filter(row -> row.Latitude != 0.0 && row.Longitude != 0.0, nodes_df)
    println("$(nrow(valid_nodes)) nodes have valid coordinates")

    # Display basic statistics
    println("\n=== NODE COORDINATES STATISTICS ===")
    println(
        "Latitude range: $(minimum(valid_nodes.Latitude)) to $(maximum(valid_nodes.Latitude))",
    )
    println(
        "Longitude range: $(minimum(valid_nodes.Longitude)) to $(maximum(valid_nodes.Longitude))",
    )

    # Group by node type
    println("\n=== NODE TYPES ===")
    type_counts = combine(groupby(valid_nodes, :TypeNode), nrow => :count)
    println(type_counts)

    # Calculate coordinate ranges for proper scaling
    lat_range = maximum(valid_nodes.Latitude) - minimum(valid_nodes.Latitude)
    lon_range = maximum(valid_nodes.Longitude) - minimum(valid_nodes.Longitude)

    # Create a colored plot by node type with equal scale ratio
    output_dir = joinpath(@__DIR__, "..", "data", "outbound")
    unique_types = unique(valid_nodes.TypeNode)
    colors = [:red, :blue, :green, :orange, :purple, :brown, :pink, :gray, :cyan, :magenta]

    fig = Figure(size = (1200, 800))
    ax = Axis(
        fig[1, 1],
        title = "Network Nodes by Type",
        xlabel = "Longitude (°)",
        ylabel = "Latitude (°)",
        aspect = DataAspect(),  # Equal scale ratio between x and y axes
        limits = (
            (
                minimum(valid_nodes.Longitude) - lon_range * 0.05,
                maximum(valid_nodes.Longitude) + lon_range * 0.05,
            ),
            (
                minimum(valid_nodes.Latitude) - lat_range * 0.05,
                maximum(valid_nodes.Latitude) + lat_range * 0.05,
            ),
        ),
    )

    # Plot each node type with different colors
    for (i, node_type) in enumerate(unique_types)
        type_nodes = filter(row -> row.TypeNode == node_type, valid_nodes)
        if nrow(type_nodes) > 0
            color = colors[min(i, length(colors))]
            scatter!(
                ax,
                type_nodes.Longitude,
                type_nodes.Latitude,
                label = node_type,
                color = color,
                markersize = 8,
                alpha = 0.7,
            )
        end
    end

    # Add legend
    axislegend(ax, position = :rt)

    # Save the colored plot
    output_file = joinpath(output_dir, "nodes_map_by_type.png")
    save(output_file, fig)
    println("Map by node type saved to: $output_file")

    # Display the figure
    display(fig)

    return fig, valid_nodes
end

# Run the visualization
println("Creating nodes map visualization...")
plot, nodes_data = visualize_nodes_map()

println("\nVisualization complete!")
println("Generated plot: nodes_map_by_type.png")
