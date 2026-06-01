"""
$TYPEDEF

A representation of a bin/truck used in bin-packing cost functions.
# Fields
$TYPEDFIELDS
"""
mutable struct Bin{C<:LightCommodity}
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
$TYPEDEF

Reusable scratch buffers for the bin-packing hot path. Created once per sweep
and threaded through `incremental_cost!` so the per-arc evaluation allocates
nothing. Single-threaded use only (one buffer per thread when parallelism
lands, mirroring STP's per-thread `CAPACITIES`).

# Fields
$TYPEDFIELDS
"""
struct BinPackingBuffer
    "remaining capacity of each currently open bin"
    caps::Vector{Float64}
    "scratch for the merged (existing union new) commodity sizes, sorted descending"
    sizes::Vector{Float64}
    "scratch for the existing run's sizes, sorted descending"
    existing_sizes::Vector{Float64}
    "scratch for the new run's sizes, sorted descending"
    new_sizes::Vector{Float64}
end

"""
$TYPEDSIGNATURES

Construct an empty `BinPackingBuffer`.
"""
function BinPackingBuffer()
    return BinPackingBuffer(Float64[], Float64[], Float64[], Float64[])
end

"""
$TYPEDSIGNATURES

First-Fit-Decreasing bin count over `sizes_desc` (already sorted descending),
reusing `buffer.caps`. Returns the number of bins. Allocates nothing in steady
state once `buffer.caps` has grown to the working size.
"""
function ffd_count!(buffer::BinPackingBuffer, bin_capacity::Float64, sizes_desc)
    empty!(buffer.caps)
    for s in sizes_desc
        placed = false
        @inbounds for i in eachindex(buffer.caps)
            if buffer.caps[i] >= s - 1e-8
                buffer.caps[i] -= s
                placed = true
                break
            end
        end
        placed || push!(buffer.caps, bin_capacity - s)
    end
    return length(buffer.caps)
end

"""
$TYPEDSIGNATURES

Merge two descending-sorted size runs `a` and `b` into `dest` (a two-pointer
descending merge). `dest` must already be sized to `length(a) + length(b)`. The
result is the descending-sorted union of the two runs, identical to sorting the
concatenation. Allocates nothing.
"""
function merge_desc!(
    dest::Vector{Float64}, a::AbstractVector{Float64}, b::AbstractVector{Float64}
)
    i = 1
    j = 1
    k = 0
    na = length(a)
    nb = length(b)
    @inbounds while i <= na && j <= nb
        if a[i] >= b[j]
            k += 1
            dest[k] = a[i]
            i += 1
        else
            k += 1
            dest[k] = b[j]
            j += 1
        end
    end
    @inbounds while i <= na
        k += 1
        dest[k] = a[i]
        i += 1
    end
    @inbounds while j <= nb
        k += 1
        dest[k] = b[j]
        j += 1
    end
    return dest
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental count. Given the remaining capacities of the already
committed (frozen) bins on an arc and the `new` commodities, pack `new` via
first-fit onto a COPY of those capacities (so the committed bins are never
mutated during a tentative evaluation) and return the number of newly opened
bins.

This is the STP packing semantics: the existing bins are not re-packed and not
re-sorted. Only `new` is sorted descending and dropped into the first frozen
bin that has room, opening a fresh bin when none fits. The result equals the
number of bins `frozen_first_fit_add!` would open on the same inputs, so the
incremental cost predicted here matches the committed bin count exactly.

`buffer.caps` is reused as the scratch for the capacities copy. `new` is read
into `buffer.new_sizes`, checked for descending order, and sorted only when
needed (the common case is already descending).
"""
function frozen_incremental_count!(
    buffer::BinPackingBuffer,
    bin_capacity::Float64,
    existing_bins::AbstractVector{<:Bin},
    new::Vector{C},
) where {C<:LightCommodity}
    isempty(new) && return 0

    # New run sizes, descending (pre-sorted at construction in the common case).
    resize!(buffer.new_sizes, length(new))
    @inbounds for (i, c) in enumerate(new)
        buffer.new_sizes[i] = c.size
    end
    _is_desc(buffer.new_sizes) || sort!(buffer.new_sizes; rev=true)

    # Copy the frozen bins' remaining capacities into scratch (never mutate the
    # committed bins here). New bins are appended to this same scratch vector.
    empty!(buffer.caps)
    for b in existing_bins
        push!(buffer.caps, b.remaining_capacity)
    end
    n_frozen = length(buffer.caps)

    @inbounds for s in buffer.new_sizes
        placed = false
        for i in eachindex(buffer.caps)
            if buffer.caps[i] >= s - 1e-8
                buffer.caps[i] -= s
                placed = true
                break
            end
        end
        placed || push!(buffer.caps, bin_capacity - s)
    end
    return length(buffer.caps) - n_frozen
end

"""
$TYPEDSIGNATURES

Frozen-bin commit. Add `new` to `bins` in place via first-fit: each commodity
(sorted descending) drops into the first existing bin with room, opening a fresh
`Bin` when none fits. The frozen bins keep their contents and only shrink their
remaining capacity, mirroring `frozen_incremental_count!` exactly so the
committed bin count agrees with the predicted incremental cost.

Returns the (possibly grown) `bins` vector. `Bin` is mutable, so a bin that
receives a commodity is updated in place (the commodity is appended and the
totals adjusted) without allocating a fresh `Bin`.

Throws `DomainError` if any commodity exceeds `bin_capacity`.
"""
function frozen_first_fit_add!(
    bins::Vector{Bin{C}}, bin_capacity::Float64, new::Vector{C}
) where {C<:LightCommodity}
    isempty(new) && return bins
    sorted_new = sort(new; by=c -> c.size, rev=true)
    if sorted_new[1].size > bin_capacity + 1e-8
        throw(
            DomainError(
                sorted_new[1],
                "Commodity size $(sorted_new[1].size) exceeds bin capacity $(bin_capacity)",
            ),
        )
    end
    for c in sorted_new
        placed = false
        @inbounds for i in eachindex(bins)
            if bins[i].remaining_capacity >= c.size - 1e-8
                push!(bins[i].commodities, c)
                bins[i].total_size += c.size
                bins[i].remaining_capacity -= c.size
                placed = true
                break
            end
        end
        if !placed
            push!(bins, Bin([c], c.size, bin_capacity, bin_capacity - c.size))
        end
    end
    return bins
end

"""
$TYPEDSIGNATURES

Compute the bin assignments for a list of commodities using the
First-Fit Decreasing (FFD) heuristic. Returns a vector of `Bin` objects.
"""
function compute_bin_assignments(
    arc_f::BinPackingArcCost, commodities::Vector{C}; presorted::Bool=false
) where {C<:LightCommodity}
    isempty(commodities) && return Bin{C}[]

    # Sort commodities in non-increasing order of size, unless the caller
    # guarantees they already are.
    sorted_commodities =
        presorted ? commodities : sort(commodities; by=c -> c.size, rev=true)

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
    arc_f::BinPackingArcCost, commodities::Vector{C}; presorted::Bool=false
) where {C<:LightCommodity}
    isempty(commodities) && return 0
    cap = arc_f.bin_capacity
    if presorted
        # First element is the largest under the descending-by-size invariant.
        first_size = commodities[1].size
        first_size > cap + 1e-8 && throw(
            DomainError(
                first_size, "Commodity size $(first_size) exceeds bin capacity $(cap)"
            ),
        )
        bin_caps = Float64[]
        for c in commodities
            s = c.size
            placed = false
            for i in eachindex(bin_caps)
                if bin_caps[i] >= s - 1e-8
                    bin_caps[i] -= s
                    placed = true
                    break
                end
            end
            placed || push!(bin_caps, cap - s)
        end
        return length(bin_caps)
    end
    sorted_sizes = sort([c.size for c in commodities]; rev=true)
    if sorted_sizes[1] > cap + 1e-8
        throw(
            DomainError(
                sorted_sizes[1],
                "Commodity size $(sorted_sizes[1]) exceeds bin capacity $(cap)",
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
            push!(bin_caps, cap - s)
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
    arc_f::BinPackingArcCost, commodities::Vector{C}; presorted::Bool=false
) where {C<:LightCommodity}
    isempty(commodities) && return 0
    cap = arc_f.bin_capacity
    if presorted
        first_size = commodities[1].size
        first_size > cap + 1e-8 && throw(
            DomainError(
                first_size, "Commodity size $(first_size) exceeds bin capacity $(cap)"
            ),
        )
        bin_caps = Float64[]
        for c in commodities
            s = c.size
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
                push!(bin_caps, cap - s)
            else
                bin_caps[best_idx] -= s
            end
        end
        return length(bin_caps)
    end
    sorted_sizes = sort([c.size for c in commodities]; rev=true)
    if sorted_sizes[1] > cap + 1e-8
        throw(
            DomainError(
                sorted_sizes[1],
                "Commodity size $(sorted_sizes[1]) exceeds bin capacity $(cap)",
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
            push!(bin_caps, cap - s)
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
    arc_f::BinPackingArcCost, commodities::Vector{C}; presorted::Bool=false
) where {C<:LightCommodity}
    isempty(commodities) && return Bin{C}[]
    sorted_commodities =
        presorted ? commodities : sort(commodities; by=c -> c.size, rev=true)
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
