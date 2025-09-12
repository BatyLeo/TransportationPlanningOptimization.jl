using CSV, DataFrames

"""
Safe parsing function that handles empty strings and missing values
"""
function safe_parse_int(s::AbstractString, default::Int = 0)
    s_trimmed = strip(s)
    if isempty(s_trimmed)
        return default
    end
    try
        return parse(Int, s_trimmed)
    catch
        return default
    end
end

function safe_parse_float(s::AbstractString, default::Float64 = 0.0)
    s_trimmed = strip(s)
    if isempty(s_trimmed)
        return default
    end
    try
        return parse(Float64, s_trimmed)
    catch
        return default
    end
end

"""
Structure to hold parsed outbound data sections
"""
struct OutboundData
    header::Dict{String,Any}
    volumes::DataFrame
    legs::DataFrame
    nodes::DataFrame
    pdc_forced::Vector{String}
    pol_forced::Vector{String}
    pod_forced::Vector{String}
    models::DataFrame
end

"""
Parse the header section of the outbound file
"""
function parse_header(lines::Vector{String}, start_idx::Int)
    header = Dict{String,Any}()

    # Expected header columns based on user specification
    expected_columns = [
        "omd",
        "PDC_max",
        "POL_Sender_max",
        "POD_RECEIVER_max",
        "Time_limit",
        "LivDirectMin_Plant",
        "LivDirectMin_Port",
        "LivDirectMin_Rail",
    ]

    # First line contains column headers
    headers = split(lines[start_idx], ';')
    # Second line contains values
    values = split(lines[start_idx+1], ';')

    for (i, expected_name) in enumerate(expected_columns)
        if i <= length(values)
            # Try to parse as number, otherwise keep as string
            value_str = strip(values[i])
            if !isempty(value_str)
                try
                    if occursin('.', value_str)
                        header[expected_name] = parse(Float64, value_str)
                    else
                        header[expected_name] = parse(Int, value_str)
                    end
                catch
                    # Handle boolean values
                    if value_str == "true"
                        header[expected_name] = true
                    elseif value_str == "false"
                        header[expected_name] = false
                    else
                        header[expected_name] = value_str
                    end
                end
            end
        end
    end

    return header, start_idx + 2
end

"""
Parse a two-row section (VOLUMES, LEGS, NODES)
Each entry spans two consecutive lines
"""
function parse_two_row_section(lines::Vector{String}, start_idx::Int, end_idx::Int)
    data = Vector{Vector{String}}()

    i = start_idx
    while i < end_idx
        # Combine two consecutive lines
        row1 = split(lines[i], ';')
        row2 = split(lines[i+1], ';')

        # Merge the two rows
        combined_row = vcat(row1, row2)
        push!(data, combined_row)

        i += 2
    end

    return data
end

"""
Parse VOLUMES section into a DataFrame
"""
function parse_volumes(lines::Vector{String}, start_idx::Int, end_idx::Int)
    data = parse_two_row_section(lines, start_idx, end_idx)

    # Create DataFrame with correct column names based on user specification
    df = DataFrame(
        model = Int[],
        usine = Int[],
        destinationFinale = Int[],
        ID = Int[],
        annee = Int[],
        semaine = Int[],
        typeBT = String[],
        volumeSemaine = Int[],
        volumeMoyenSemaine = Int[],
        volumeMEdSemaine = Int[],
        volumeAnnuel = Int[],
        volumetotal = Int[],
    )

    for row in data
        if length(row) >= 12
            push!(
                df,
                (
                    safe_parse_int(row[1]),          # model
                    safe_parse_int(row[2]),          # usine
                    safe_parse_int(row[3]),          # destinationFinale
                    safe_parse_int(row[4]),          # ID
                    safe_parse_int(row[5]),          # annee
                    safe_parse_int(row[6]),          # semaine
                    strip(row[7]),                   # typeBT
                    safe_parse_int(row[8]),          # volumeSemaine
                    safe_parse_int(row[9]),          # volumeMoyenSemaine
                    safe_parse_int(row[10]),         # volumeMEdSemaine
                    safe_parse_int(row[11]),         # volumeAnnuel
                    safe_parse_int(row[12]),         # volumetotal
                ),
            )
        end
    end

    return df
end

"""
Parse LEGS section into a DataFrame
"""
function parse_legs(lines::Vector{String}, start_idx::Int, end_idx::Int)
    data = parse_two_row_section(lines, start_idx, end_idx)

    # Correct column names based on user specification
    df = DataFrame(
        origine = Int[],
        destination = Int[],
        TypeLeg = String[],
        model = Int[],
        Cost = Float64[],
        VolMin = Int[],
        VolMax = Int[],
    )

    for row in data
        if length(row) >= 7
            push!(
                df,
                (
                    safe_parse_int(row[1]),        # origine
                    safe_parse_int(row[2]),        # destination
                    strip(row[3]),                 # TypeLeg
                    safe_parse_int(row[4]),        # model
                    safe_parse_float(row[5]),      # Cost
                    safe_parse_int(row[6]),        # VolMin
                    safe_parse_int(row[7]),        # VolMax
                ),
            )
        end
    end

    return df
end

"""
Parse a three-row section (NODES)
Each entry spans three consecutive lines
"""
function parse_three_row_section(lines::Vector{String}, start_idx::Int, end_idx::Int)
    data = Vector{Vector{String}}()

    i = start_idx
    while i < end_idx - 1  # Need at least 2 more lines
        # Combine three consecutive lines
        row1 = split(lines[i], ';')
        row2 = split(lines[i+1], ';')
        row3 = split(lines[i+2], ';')

        # Merge the three rows
        combined_row = vcat(row1, row2, row3)
        push!(data, combined_row)

        i += 3
    end

    return data
end

"""
Parse NODES section into a DataFrame
"""
function parse_nodes(lines::Vector{String}, start_idx::Int, end_idx::Int)
    data = parse_three_row_section(lines, start_idx, end_idx)

    # Base columns from first row
    df = DataFrame(
        indice = Int[],
        nom = String[],
        nomReel = String[],
        TypeNode = String[],
        TypePort = String[],
        Latitude = Float64[],
        Longitude = Float64[],
        nombreCandidatStockBTS = Int[],
        ListeCandidatStockBTS = String[],  # From second row
        NBmodel = Int[],  # From third row
        model_configs = String[],  # Store the dynamic model configurations as string
    )

    for row in data
        # Extract basic node information (first 8 columns from first row)
        indice = safe_parse_int(row[1])
        nom = strip(row[2])
        nomReel = strip(row[3])
        TypeNode = strip(row[4])
        TypePort = strip(row[5])
        Latitude = safe_parse_float(row[6])
        Longitude = safe_parse_float(row[7])
        nombreCandidatStockBTS = safe_parse_int(row[8])

        # Second row - ListeCandidatStockBTS
        ListeCandidatStockBTS = length(row) > 8 ? strip(row[9]) : ""

        # Third row starts with NBmodel, then model configurations
        NBmodel = length(row) > 9 ? safe_parse_int(row[10]) : 0

        # Collect remaining model configuration as a single string
        model_configs = ""
        if length(row) > 10
            model_parts = row[11:end]
            model_configs = join(model_parts, ";")
        end

        push!(
            df,
            (
                indice,
                nom,
                nomReel,
                TypeNode,
                TypePort,
                Latitude,
                Longitude,
                nombreCandidatStockBTS,
                ListeCandidatStockBTS,
                NBmodel,
                model_configs,
            ),
        )
    end

    return df
end

"""
Parse single-line sections (PDCFORCED, POLFORCED, PODFORCED)
"""
function parse_single_line_section(lines::Vector{String}, start_idx::Int, end_idx::Int)
    data = Vector{String}()
    for i = start_idx:(end_idx-1)
        line = strip(lines[i])
        if !isempty(line)
            push!(data, line)
        end
    end
    return data
end

"""
Parse MODELES section into a DataFrame
"""
function parse_models(lines::Vector{String}, start_idx::Int, end_idx::Int)
    # Correct column names based on user specification
    df = DataFrame(indice = Int[], modelName = String[])

    for i = start_idx:(end_idx-1)
        parts = split(lines[i], ';')
        if length(parts) >= 2
            push!(df, (
                safe_parse_int(parts[1]),    # indice
                strip(parts[2]),             # modelName
            ))
        end
    end

    return df
end

"""
Main function to parse the entire outbound file
"""
function parse_outbound_file(file_path::String)
    lines = readlines(file_path)

    # Find section boundaries
    section_indices = Dict{String,Int}()
    for (i, line) in enumerate(lines)
        line_trimmed = strip(line)
        if line_trimmed in [
            "VOLUMES;",
            "LEGS;",
            "NODES;",
            "PDCFORCED;",
            "POLFORCED;",
            "PODFORCED;",
            "MODELES;",
            "FIN;",
        ]
            section_indices[replace(line_trimmed, ";" => "")] = i
        end
    end

    # Parse header (before VOLUMES)
    header, volumes_start = parse_header(lines, 1)

    # Parse sections
    volumes_data =
        parse_volumes(lines, section_indices["VOLUMES"] + 1, section_indices["LEGS"])

    legs_data = parse_legs(lines, section_indices["LEGS"] + 1, section_indices["NODES"])

    nodes_data =
        parse_nodes(lines, section_indices["NODES"] + 1, section_indices["PDCFORCED"])

    pdc_forced = parse_single_line_section(
        lines,
        section_indices["PDCFORCED"] + 1,
        section_indices["POLFORCED"],
    )

    pol_forced = parse_single_line_section(
        lines,
        section_indices["POLFORCED"] + 1,
        section_indices["PODFORCED"],
    )

    pod_forced = parse_single_line_section(
        lines,
        section_indices["PODFORCED"] + 1,
        section_indices["MODELES"],
    )

    models_data =
        parse_models(lines, section_indices["MODELES"] + 1, section_indices["FIN"])

    return OutboundData(
        header,
        volumes_data,
        legs_data,
        nodes_data,
        pdc_forced,
        pol_forced,
        pod_forced,
        models_data,
    )
end

# Example usage
data_dir = joinpath(@__DIR__, "..", "data", "outbound")
outbound_file = joinpath(data_dir, "HexData.csv")

# Parse the file
println("Parsing outbound file: $outbound_file")
outbound_data = parse_outbound_file(outbound_file)

# Print summary information
println("\n=== OUTBOUND DATA SUMMARY ===")
println("Header parameters:")
for (key, value) in outbound_data.header
    println("  $key: $value")
end

println("\nData sections:")
println("  VOLUMES: $(nrow(outbound_data.volumes)) entries")
println("  LEGS: $(nrow(outbound_data.legs)) entries")
println("  NODES: $(nrow(outbound_data.nodes)) entries")
println("  PDC_FORCED: $(length(outbound_data.pdc_forced)) entries")
println("  POL_FORCED: $(length(outbound_data.pol_forced)) entries")
println("  POD_FORCED: $(length(outbound_data.pod_forced)) entries")
println("  MODELS: $(nrow(outbound_data.models)) entries")

# Display first few rows of each section
println("\n=== SAMPLE DATA ===")
if nrow(outbound_data.volumes) > 0
    println("\nFirst 5 VOLUMES entries:")
    println(first(outbound_data.volumes, 5))
end

if nrow(outbound_data.legs) > 0
    println("\nFirst 5 LEGS entries:")
    println(first(outbound_data.legs, 5))
end

if nrow(outbound_data.nodes) > 0
    println("\nFirst 5 NODES entries:")
    println(first(outbound_data.nodes, 5))
end

if nrow(outbound_data.models) > 0
    println("\nMODELS:")
    println(outbound_data.models)
end

"""
Export parsed data to separate CSV files
"""
function export_parsed_data(data::OutboundData, output_dir::String)
    mkpath(output_dir)

    # Export main sections
    CSV.write(joinpath(output_dir, "parsed_volumes.csv"), data.volumes)
    CSV.write(joinpath(output_dir, "parsed_legs.csv"), data.legs)
    CSV.write(joinpath(output_dir, "parsed_nodes.csv"), data.nodes)
    CSV.write(joinpath(output_dir, "parsed_models.csv"), data.models)

    # Export header as a simple key-value CSV
    header_df = DataFrame(parameter = String[], value = String[])
    for (key, value) in data.header
        push!(header_df, (string(key), string(value)))
    end
    CSV.write(joinpath(output_dir, "parsed_header.csv"), header_df)

    println("\nParsed data exported to: $output_dir")
    println("Files created:")
    println("  - parsed_header.csv")
    println("  - parsed_volumes.csv")
    println("  - parsed_legs.csv")
    println("  - parsed_nodes.csv")
    println("  - parsed_models.csv")
end

# Export parsed data
export_dir = joinpath(dirname(outbound_file), "parsed")
export_parsed_data(outbound_data, export_dir)
