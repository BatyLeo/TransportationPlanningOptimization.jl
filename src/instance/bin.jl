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

    # Check for oversized commodities after sorting (in case of numerical issues)
    if sorted_commodities[1].size > arc_f.bin_capacity + 1e-8
        throw(
            DomainError(
                sorted_commodities[1],
                "Commodity size $(sorted_commodities[1].size) exceeds bin capacity $(arc_f.bin_capacity)",
            ),
        )
    end

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

"""
$TYPEDSIGNATURES

Return the number of bins First-Fit-Decreasing would open for `commodities`
under `arc_f`, without allocating any `Bin` object. The result is exact, not
a bound, and satisfies `tentative_bin_count(arc_f, items) ==
length(compute_bin_assignments(arc_f, items))` for any input.

Prefer this over `compute_bin_assignments` whenever only the bin count is
needed (for example, in cost-matrix updates and local-search delta
evaluations where the `BinPackingArcCost` evaluates to
`cost_per_bin * n_bins`). Use `compute_bin_assignments` when the actual
bin contents are needed downstream.

Throws `DomainError` if any commodity exceeds `arc_f.bin_capacity`.
"""
function tentative_bin_count(
    arc_f::BinPackingArcCost, commodities::Vector{C}
) where {C<:LightCommodity}
    isempty(commodities) && return 0
    sorted_sizes = sort([c.size for c in commodities]; rev=true)
    if sorted_sizes[1] > arc_f.bin_capacity + 1e-8
        throw(
            DomainError(
                sorted_sizes[1],
                "Commodity size $(sorted_sizes[1]) exceeds bin capacity $(arc_f.bin_capacity)",
            ),
        )
    end
    bin_caps = Float64[]
    for s in sorted_sizes
        placed = false
        for i in eachindex(bin_caps)
            if bin_caps[i] >= s - 1e-8
                bin_caps[i] -= s
                placed = true
                break
            end
        end
        if !placed
            push!(bin_caps, arc_f.bin_capacity - s)
        end
    end
    return length(bin_caps)
end

"""
$TYPEDSIGNATURES

Return the number of bins Best-Fit Decreasing (BFD) would open for
`commodities` under `arc_f`, without allocating any `Bin` object. Mirror of
`tentative_bin_count` for the BFD heuristic. The result is exact, not a
bound, and satisfies `tentative_best_fit_count(arc_f, items) ==
length(compute_bin_assignments_bfd(arc_f, items))` for any input.

Use this alongside `tentative_bin_count` in `bin_packing_improvement!` to
gate the BFD-vs-FFD choice without materializing either packing.

Throws `DomainError` if any commodity exceeds `arc_f.bin_capacity`.
"""
function tentative_best_fit_count(
    arc_f::BinPackingArcCost, commodities::Vector{C}
) where {C<:LightCommodity}
    isempty(commodities) && return 0
    sorted_sizes = sort([c.size for c in commodities]; rev=true)
    if sorted_sizes[1] > arc_f.bin_capacity + 1e-8
        throw(
            DomainError(
                sorted_sizes[1],
                "Commodity size $(sorted_sizes[1]) exceeds bin capacity $(arc_f.bin_capacity)",
            ),
        )
    end
    bin_caps = Float64[]
    for s in sorted_sizes
        best_idx = 0
        best_left = Inf
        for i in eachindex(bin_caps)
            after = bin_caps[i] - s
            if after >= -1e-8 && after < best_left
                best_left = after
                best_idx = i
            end
        end
        if best_idx == 0
            push!(bin_caps, arc_f.bin_capacity - s)
        else
            bin_caps[best_idx] -= s
        end
    end
    return length(bin_caps)
end

"""
$TYPEDSIGNATURES

Compute the bin assignments for `commodities` using Best-Fit Decreasing
(BFD). Returns a vector of `Bin` objects. Use this when BFD predicts fewer
bins than FFD. Otherwise prefer `compute_bin_assignments` (FFD), which is
typically a hair faster.

Throws `DomainError` if any commodity exceeds `arc_f.bin_capacity`.
"""
function compute_bin_assignments_bfd(
    arc_f::BinPackingArcCost, commodities::Vector{C}
) where {C<:LightCommodity}
    isempty(commodities) && return Bin{C}[]
    sorted_commodities = sort(commodities; by=c -> c.size, rev=true)
    if sorted_commodities[1].size > arc_f.bin_capacity + 1e-8
        throw(
            DomainError(
                sorted_commodities[1],
                "Commodity size $(sorted_commodities[1].size) exceeds bin capacity $(arc_f.bin_capacity)",
            ),
        )
    end
    bin_contents = Vector{C}[]
    bin_rem_caps = Float64[]
    for c in sorted_commodities
        best_idx = 0
        best_left = Inf
        for i in eachindex(bin_rem_caps)
            after = bin_rem_caps[i] - c.size
            if after >= -1e-8 && after < best_left
                best_left = after
                best_idx = i
            end
        end
        if best_idx == 0
            push!(bin_contents, [c])
            push!(bin_rem_caps, arc_f.bin_capacity - c.size)
        else
            push!(bin_contents[best_idx], c)
            bin_rem_caps[best_idx] -= c.size
        end
    end
    return [
        Bin(
            bin_contents[i],
            arc_f.bin_capacity - bin_rem_caps[i],
            Float64(arc_f.bin_capacity),
            bin_rem_caps[i],
        ) for i in eachindex(bin_contents)
    ]
end
