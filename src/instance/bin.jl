"""
$TYPEDEF

A representation of a bin/truck used in bin-packing cost functions.
# Fields
$TYPEDFIELDS
"""
struct Bin{C<:LightCommodity}
    "List of commodities assigned to this bin"
    commodities::Vector{C}
    "Total size of all commodities in the bin"
    total_size::Float64
    "Capacity of the bin"
    max_capacity::Float64
    "Remaining capacity in the bin"
    remaining_capacity::Float64
end

function Base.show(io::IO, bin::Bin)
    return println(io, "$(bin.total_size) / $(bin.max_capacity)")
end

"""
$TYPEDSIGNATURES

Compute the bin assignments for a list of commodities using the
First-Fit Decreasing (FFD) heuristic. Returns a vector of `Bin` objects.
"""
function compute_bin_assignments(
    arc_f::BinPackingArcCost, commodities::Vector{C}
) where {C<:LightCommodity}
    isempty(commodities) && return Bin{C}[]

    # Sort commodities in non-increasing order of size
    sorted_commodities = sort(commodities; by=c -> c.size, rev=true)

    # Temporary storage for bin contents and remaining capacities
    bin_contents = Vector{C}[]
    bin_rem_caps = Float64[]

    for c in sorted_commodities
        placed = false
        # Try to fit in the first available bin (allow a small numerical tolerance)
        for i in eachindex(bin_contents)
            if bin_rem_caps[i] >= c.size - 1e-8
                push!(bin_contents[i], c)
                bin_rem_caps[i] -= c.size
                placed = true
                break
            end
        end

        # If it doesn't fit in any existing bin, open a new one
        if !placed
            push!(bin_contents, [c])
            push!(bin_rem_caps, arc_f.bin_capacity - c.size)
        end
    end

    # Convert to Bin objects
    return [
        Bin(
            bin_contents[i],
            arc_f.bin_capacity - bin_rem_caps[i],
            Float64(arc_f.bin_capacity),
            bin_rem_caps[i],
        ) for i in eachindex(bin_contents)
    ]
end
