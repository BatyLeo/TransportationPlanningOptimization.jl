"""
$TYPEDEF

A representation of a bin/truck used in bin-packing cost functions.

# Fields
$TYPEDFIELDS
"""
mutable struct Bin{C<:LightCommodity}
    "List of commodities assigned to this bin"
    commodities::Vector{C}
    "Remaining capacity in the bin"
    remaining_capacity::Float64
end

function Base.show(io::IO, bin::Bin)
    return print(
        io,
        "Bin(",
        length(bin.commodities),
        " commodities, remaining=",
        bin.remaining_capacity,
        ")",
    )
end

"""
$TYPEDEF

Reusable buffers for bin-packing. Created once and threaded through `incremental_cost!`
so the per-arc evaluation allocates nothing.
Single-threaded use only (one buffer per thread once parallelism is implemented and used).

# Fields
$TYPEDFIELDS
"""
struct BinPackingBuffer{T<:Real}
    "remaining capacity of each currently open bin"
    remaining_capacities::Vector{T}
    "scratch for extracting existing commodity sizes, sorted descending"
    existing_sizes::Vector{T}
end

"""
$TYPEDSIGNATURES

Construct an empty `BinPackingBuffer`.
"""
function BinPackingBuffer(::Type{T}=Float64) where {T<:Real}
    return BinPackingBuffer{T}(T[], T[])
end

# Init and get remaining capacity vector: a buffer-owned one (cleared) or a fresh one.
@inline _init_remaining_capacities(::Nothing) = Float64[]
@inline function _init_remaining_capacities(buffer::BinPackingBuffer)
    empty!(buffer.remaining_capacities)
    return buffer.remaining_capacities
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

"""
$TYPEDSIGNATURES

Return `true` if `commodities` is sorted in non-increasing order by `.size`.
Used by `@boundscheck` asserts on the `incremental_cost!` / `frozen_incremental_count!`
precondition that the `new` run arrives pre-sorted descending.
"""
@inline function _commodities_is_desc(
    commodities::AbstractVector{C}
) where {C<:LightCommodity}
    @inbounds for i in 2:length(commodities)
        if commodities[i - 1].size < commodities[i].size
            return false
        end
    end
    return true
end

# Throws `DomainError` if oversize
@inline function _check_oversize(largest_size::Real, cap::Real; eps=EPS)
    largest_size > cap + eps && throw(
        DomainError(
            largest_size, "Commodity size $(largest_size) exceeds bin capacity $(cap)"
        ),
    )
    return nothing
end

"""
$TYPEDSIGNATURES

Return the index of the first bin in `remaining_capacities` that can fit an
item of size `s`, or `0` if none can.
"""
@inline function _first_fit_index(remaining_capacities, s; eps=EPS)
    @inbounds for i in eachindex(remaining_capacities)
        remaining_capacities[i] >= s - eps && return i
    end
    return 0
end

"""
$TYPEDSIGNATURES

Return the index of the best-fit bin in `remaining_capacities` for an item of
size `s` (tightest fit), or `0` if none can accommodate it.
"""
@inline function _best_fit_index(
    remaining_capacities::AbstractVector{T}, s; eps=EPS
) where {T<:Real}
    best_idx = 0
    best_left = typemax(T)
    @inbounds for i in eachindex(remaining_capacities)
        after = remaining_capacities[i] - s
        if after >= -eps && after < best_left
            best_left = after
            best_idx = i
        end
    end
    return best_idx
end

"""
$TYPEDSIGNATURES

First-Fit-Decreasing placement loop. Walks `sizes_desc` (assumed sorted
descending), placing each into the first slot of `caps` with room, otherwise
opening a new slot with capacity `cap - s`. Mutates `caps` in place.
"""
@inline function _ffd_place!(
    remaining_capacities::Vector{T}, sizes_desc, cap::T; eps=EPS
) where {T<:Real}
    @inbounds for s in sizes_desc
        idx = _first_fit_index(remaining_capacities, s; eps)
        # If a bin was found, subtract the size from its remaining capacity.
        if idx > 0
            remaining_capacities[idx] -= s
        else # else, create a new bin with remaining capacity `cap - s`.
            push!(remaining_capacities, cap - s)
        end
    end
    return remaining_capacities
end

"""
$TYPEDSIGNATURES

First-Fit-Decreasing placement iterating a `Vector{C}` of commodities directly,
reading `c.size` per element. Equivalent to `_ffd_place!(caps, (c.size for c in items), cap)`.
`items` must be sorted descending by `.size`.
"""
@inline function _ffd_place_commodities!(
    remaining_capacities::Vector{Float64}, items::AbstractVector{C}, cap::Float64; eps=EPS
) where {C<:LightCommodity}
    @inbounds for c in items
        s = c.size
        idx = _first_fit_index(remaining_capacities, s; eps)
        # If a bin was found, subtract the size from its remaining capacity.
        if idx > 0
            remaining_capacities[idx] -= s
        else # else, create a new bin with remaining capacity `cap - s`.
            push!(remaining_capacities, cap - s)
        end
    end
    return remaining_capacities
end

"""
$TYPEDSIGNATURES

First-Fit-Decreasing placement over the descending union of a pre-sorted
descending `Vector{Float64}` and a pre-sorted descending `Vector{C}` of
commodities. Mirror of `_ffd_place_merged!` that avoids materializing the
commodity sizes into a separate buffer.
"""
@inline function _ffd_place_merged_with_commodities!(
    remaining_capacities::Vector{Float64},
    a::AbstractVector{Float64},
    b::AbstractVector{C},
    cap::Float64;
    eps=EPS,
) where {C<:LightCommodity}
    i, j = 1, 1
    na, nb = length(a), length(b)
    @inbounds while i <= na || j <= nb
        s = if j > nb
            x = a[i]
            i += 1
            x
        elseif i > na
            x = b[j].size
            j += 1
            x
        else
            va = a[i]
            vb = b[j].size
            if va >= vb
                i += 1
                va
            else
                j += 1
                vb
            end
        end
        idx = _first_fit_index(remaining_capacities, s; eps)
        # If a bin was found, subtract the size from its remaining capacity.
        if idx > 0
            remaining_capacities[idx] -= s
        else # else, create a new bin with remaining capacity `cap - s`.
            push!(remaining_capacities, cap - s)
        end
    end
    return remaining_capacities
end

"""
$TYPEDSIGNATURES

First-Fit-Decreasing placement over the descending union of two pre-sorted
descending vectors `a` and `b`. Reads the union in descending order without materializing
the merged vector. Equivalent to `_ffd_place!(caps, merged, cap)` where
`merged = sort(vcat(a, b); rev=true)`.
"""
@inline function _ffd_place_merged!(
    remaining_capacities::Vector{T},
    a::AbstractVector{T},
    b::AbstractVector{T},
    cap::T;
    eps=EPS,
) where {T<:Real}
    i, j = 1, 1
    na, nb = length(a), length(b)
    @inbounds while i <= na || j <= nb
        s = if j > nb
            x = a[i]
            i += 1
            x
        elseif i > na
            x = b[j]
            j += 1
            x
        elseif a[i] >= b[j]
            x = a[i]
            i += 1
            x
        else
            x = b[j]
            j += 1
            x
        end
        idx = _first_fit_index(remaining_capacities, s; eps)
        # If a bin was found, subtract the size from its remaining capacity.
        if idx > 0
            remaining_capacities[idx] -= s
        else # else, create a new bin with remaining capacity `cap - s`.
            push!(remaining_capacities, cap - s)
        end
    end
    return remaining_capacities
end

"""
$TYPEDSIGNATURES

Best-Fit-Decreasing placement loop. Mirror of `_ffd_place!` for BFD.
"""
@inline function _bfd_place!(
    remaining_capacities::Vector{T}, sizes_desc, cap::T; eps=EPS
) where {T<:Real}
    @inbounds for s in sizes_desc
        idx = _best_fit_index(remaining_capacities, s; eps)
        # If a bin was found, subtract the size from its remaining capacity.
        if idx > 0
            remaining_capacities[idx] -= s
        else # else, create a new bin with remaining capacity `cap - s`.
            push!(remaining_capacities, cap - s)
        end
    end
    return remaining_capacities
end

"""
$TYPEDSIGNATURES

Materializing First-Fit-Decreasing placement. Mirrors `_ffd_place!` but also
tracks per-bin commodity lists in `bin_contents`.
`bin_contents[i]` holds the commodities placed in bin `i` (with remaining
capacity `remaining_capacities[i]`).
`sorted_commodities` must be descending by `.size`.
"""
@inline function _ffd_assign!(
    bin_contents::Vector{Vector{C}},
    remaining_capacities::Vector{Float64},
    sorted_commodities,
    cap::Float64;
    eps=EPS,
) where {C<:LightCommodity}
    @inbounds for c in sorted_commodities
        s = c.size
        idx = _first_fit_index(remaining_capacities, s; eps)
        # If a bin was found, subtract the size from its remaining capacity,
        # and add the commodity to that bin's contents.
        if idx > 0
            push!(bin_contents[idx], c)
            remaining_capacities[idx] -= s
        else # else, create a new bin with remaining capacity `cap - s` and add the commodity to it.
            push!(bin_contents, [c])
            push!(remaining_capacities, cap - s)
        end
    end
    return bin_contents
end

"""
$TYPEDSIGNATURES

Materializing Best-Fit-Decreasing placement. Mirror of `_ffd_assign!` for BFD.
"""
@inline function _bfd_assign!(
    bin_contents::Vector{Vector{C}},
    caps::Vector{Float64},
    sorted_commodities,
    cap::Float64;
    eps=EPS,
) where {C<:LightCommodity}
    @inbounds for c in sorted_commodities
        s = c.size
        idx = _best_fit_index(caps, s; eps)
        if idx > 0
            push!(bin_contents[idx], c)
            caps[idx] -= s
        else
            push!(bin_contents, [c])
            push!(caps, cap - s)
        end
    end
    return bin_contents
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
$TYPEDSIGNATURES

First-Fit-Decreasing bin count over `sizes_desc` (already sorted descending), reusing
`buffer.remaining_capacities`. Returns the number of bins.
Allocates nothing in steady state once `buffer.remaining_capacities` has grown to the
working size.

!!! note
    `empty!` only resets the length to 0 without releasing the backing buffer,
    so `buffer.remaining_capacities` grows at most to the largest working size seen and never
    allocates after that.
"""
function ffd_count!(
    buffer::BinPackingBuffer{T}, bin_capacity::T, sizes_desc; eps=EPS
) where {T<:Real}
    empty!(buffer.remaining_capacities)
    _ffd_place!(buffer.remaining_capacities, sizes_desc, bin_capacity; eps)
    return length(buffer.remaining_capacities)
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental count. Given the remaining capacities of the already
committed (frozen) bins on an arc and the `new` commodities, pack `new` via
first-fit onto a copy of those capacities (committed bins are never mutated)
and return the number of newly opened bins.
`new` MUST be sorted descending by `.size`
"""
function frozen_incremental_count!(
    buffer::BinPackingBuffer,
    bin_capacity::Float64,
    existing_bins::AbstractVector{<:Bin},
    new::Vector{C},
) where {C<:LightCommodity}
    isempty(new) && return 0
    @boundscheck _commodities_is_desc(new) ||
        throw(ArgumentError("`new` must be sorted descending by `.size`"))

    n_frozen = length(existing_bins)
    resize!(buffer.remaining_capacities, n_frozen)
    @inbounds for i in 1:n_frozen
        buffer.remaining_capacities[i] = existing_bins[i].remaining_capacity
    end

    _ffd_place_commodities!(buffer.remaining_capacities, new, bin_capacity)
    return length(buffer.remaining_capacities) - n_frozen
end

"""
$TYPEDSIGNATURES

Frozen-bin commit. Add `new` to `bins` in place via first-fit.
The frozen bins keep their contents and only shrink their remaining capacity.

Returns the (possibly grown) `bins` vector. `Bin` is mutable, so a bin that
receives a commodity is updated in place (the commodity is appended and the
totals adjusted) without allocating a fresh `Bin`.

Throws `DomainError` if any commodity exceeds `bin_capacity`.
"""
function frozen_first_fit_add!(
    bins::Vector{Bin{C}}, bin_capacity::Float64, new::Vector{C}
) where {C<:LightCommodity}
    isempty(new) && return bins
    @boundscheck _commodities_is_desc(new) ||
        throw(ArgumentError("`new` must be sorted descending by `.size`"))
    _check_oversize(new[1].size, bin_capacity)
    caps = [b.remaining_capacity for b in bins]
    for c in new
        idx = _first_fit_index(caps, c.size)
        if idx > 0
            push!(bins[idx].commodities, c)
            bins[idx].remaining_capacity -= c.size
            caps[idx] -= c.size
        else
            push!(bins, Bin([c], bin_capacity - c.size))
            push!(caps, bin_capacity - c.size)
        end
    end
    return bins
end
