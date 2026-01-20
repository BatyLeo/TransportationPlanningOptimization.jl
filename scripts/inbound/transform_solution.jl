using CSV
using DataFrames

"""
    transform_solution_csv(input_file::String, output_file::String)

Transform a CSV file with format:
`route_id,supplier_account,customer_account,point_account,point_number,point_type`
into a format compatible with `read_solution_csv`:
`route_id,origin_id,destination_id,node_id,point_number,point_type`

Mapping:
- `supplier_account` -> `origin_id`
- `customer_account` -> `destination_id`
- `point_account` -> `node_id`
- `point_type`: "supplier" -> "origin", "plant" -> "destination", everything else -> "other"
"""
function transform_solution_csv(input_file::String, output_file::String)
    if !isfile(input_file)
        error("Input file not found: $input_file")
    end

    df = CSV.read(input_file, DataFrame)

    # Rename columns to match internal Solution format
    rename_map = Dict(
        :supplier_account => :origin_id,
        :customer_account => :destination_id,
        :point_account => :node_id,
    )

    # Only rename if they exist
    for (old, new) in rename_map
        if old in propertynames(df)
            rename!(df, old => new)
        end
    end

    # Update point types
    if :point_type in propertynames(df)
        df.point_type = map(df.point_type) do pt
            pt_str = lowercase(string(pt))
            if pt_str == "supplier"
                return "origin"
            elseif pt_str == "plant"
                return "destination"
            else
                return "other"
            end
        end
    end

    CSV.write(output_file, df)
    return println("✅ Transformed $input_file to $output_file")
end

# Check if script is run directly
if abspath(PROGRAM_FILE) == @__FILE__
    if length(ARGS) < 1
        println("Usage: julia transform_solution.jl <input_file> [output_file]")
    else
        input = ARGS[1]
        output = length(ARGS) >= 2 ? ARGS[2] : "transformed_solution.csv"
        transform_solution_csv(input, output)
    end
end
