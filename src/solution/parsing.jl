using CSV
using DataFrames

"""
    write_solution_csv(filename::String, sol::Solution, instance::Instance)

Write the solution to a CSV file in the following format:
`route_id,origin_id,destination_id,node_id,point_number,point_type`

The paths are written in **reverse order** (from destination to origin) to match the user's requested format.
"""
function write_solution_csv(filename::String, sol::Solution, instance::Instance)
    ttg = instance.travel_time_graph
    df = DataFrame(;
        bundle_idx=Int[],
        origin_id=String[],
        destination_id=String[],
        node_id=String[],
        point_number=Int[],
        point_type=Symbol[],
    )

    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        if isempty(path)
            continue
        end

        bundle = instance.bundles[bundle_idx]
        # Reverse the path for writing (destination to origin)
        reversed_path = reverse(path)

        for (i, node_code) in enumerate(reversed_path)
            # Label is (spatial_node_id, tau)
            label = MetaGraphsNext.label_for(ttg.graph, node_code)
            spatial_node_id = label[1]

            point_type = if i == 1
                :destination
            elseif i == length(path)
                :origin
            else
                :other
            end

            push!(
                df,
                (
                    bundle_idx,
                    bundle.origin_id,
                    bundle.destination_id,
                    spatial_node_id,
                    i,
                    point_type,
                ),
            )
        end
    end

    CSV.write(filename, df)
    return nothing
end

"""
    read_solution_csv(filename::String, instance::Instance)

Read a solution from a CSV file and reconstruct the `Solution` object.
Assumes the CSV follows the format: `route_id,origin_id,destination_id,node_id,point_number,point_type`.
"""
function read_solution_csv(filename::String, instance::Instance)
    # Read CSV, forcing ID columns to be strings to avoid inference issues with numeric IDs
    df = CSV.read(
        filename,
        DataFrame;
        types=Dict(
            :origin_id => String,
            :destination_id => String,
            :node_id => String,
            :bundle_idx => Int,
        ),
        validate=false,
    )
    ttg = instance.travel_time_graph

    # Required columns
    required_cols = [
        :bundle_idx, :origin_id, :destination_id, :node_id, :point_number, :point_type
    ]
    missing = setdiff(required_cols, Symbol.(names(df)))
    if !isempty(missing)
        error(
            "CSV missing required columns: $(join(missing, ", ")). Required columns are: $(join(required_cols, ", ")).",
        )
    end

    n_bundles = bundle_count(instance)

    # Validate bundle_idx values
    if any(x -> !(x isa Integer), df.bundle_idx)
        error("`bundle_idx` column must contain integer bundle indices")
    end
    if any(x -> x < 1 || x > n_bundles, df.bundle_idx)
        error("`bundle_idx` contains out-of-range values; valid range is 1:$n_bundles")
    end

    # Build mapping of spatial node id -> timed node codes for validation and faster lookup
    spatial_to_codes = Dict{String,Vector{Int}}()
    for code in Graphs.vertices(ttg.graph)
        label = MetaGraphsNext.label_for(ttg.graph, code)
        s = string(label[1])
        push!(get!(spatial_to_codes, s, Int[]), code)
    end

    # Ensure all node_id in CSV exist as spatial nodes
    for s in unique(string.(df.node_id))
        if !haskey(spatial_to_codes, s)
            error("Node id `$s` from CSV not found in TTG spatial nodes")
        end
    end

    # Pre-allocate bundle paths
    bundle_paths = [Int[] for _ in 1:n_bundles]

    # Process each bundle using bundle_idx
    gd = groupby(df, :bundle_idx)
    for sub_df in gd
        bidx = Int(sub_df.bundle_idx[1])

        # Validate point numbers are unique per bundle
        pn = sub_df.point_number
        if length(unique(pn)) != length(pn)
            error("Duplicate point_number for bundle_idx $bidx")
        end

        # Sort by point_number to ensure correct sequence (destination to origin in user format)
        sorted_rows = sort(sub_df, :point_number)

        # Original path is sequence from origin to destination (reverse of CSV order)
        spatial_sequence = reverse(string.(sorted_rows.node_id))

        # Reconstruct the timed path in TTG
        # Start at the bundle's origin entry node
        current_code = ttg.origin_codes[bidx]
        ttg_path = [current_code]

        # Iterate through jumps in spatial sequence (start from second node)
        for j in 2:length(spatial_sequence)
            target_spatial_id = spatial_sequence[j]

            # BFS to find path from current_code to any timed node with target_spatial_id
            queue = [(current_code, Int[])]
            visited = Set{Int}([current_code])
            found_path_segment = nothing

            while !isempty(queue)
                (u_code, path_acc) = popfirst!(queue)
                u_label = MetaGraphsNext.label_for(ttg.graph, u_code)

                if string(u_label[1]) == target_spatial_id && u_code != current_code
                    found_path_segment = path_acc
                    current_code = u_code
                    break
                end

                for v_code in Graphs.outneighbors(ttg.graph, u_code)
                    if v_code ∉ visited
                        push!(visited, v_code)
                        push!(queue, (v_code, [path_acc; v_code]))
                    end
                end
            end

            if isnothing(found_path_segment)
                error(
                    "Could not find a valid TTG path from $(MetaGraphsNext.label_for(ttg.graph, current_code)) to spatial node $target_spatial_id for bundle $bidx",
                )
            end

            append!(ttg_path, found_path_segment)
        end

        # Verify the path ends at the correct destination exit node
        expected_dest = ttg.destination_codes[bidx]
        if current_code != expected_dest
            @warn "Reconstructed path for bundle $bidx ends at $(MetaGraphsNext.label_for(ttg.graph, current_code)), but expected $(MetaGraphsNext.label_for(ttg.graph, expected_dest))"
        end

        bundle_paths[bidx] = ttg_path
    end

    return Solution(bundle_paths, instance)
end
