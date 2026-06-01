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
so the per-arc evaluation allocates nothing. Single-threaded use only (one buffer per thread
once parallelism is implemented and used).

# Fields
$TYPEDFIELDS
"""
struct BinPackingBuffer{T<:Real}
    "remaining capacity of each currently open bin"
    remaining_capacities::Vector{T}
    "scratch for the existing run's sizes, sorted descending"
    existing_sizes::Vector{T}
end

"""
$TYPEDSIGNATURES

Construct an empty `BinPackingBuffer`.
"""
function BinPackingBuffer(::Type{T}=Float64) where {T<:Real}
    return BinPackingBuffer{T}(T[], T[])
end

"""
Return `true` if `commodities` is sorted in non-increasing order by `.size`.
Used by `@boundscheck` asserts on the `incremental_cost!` / `frozen_incremental_count!`
precondition that the `new` run arrives pre-sorted descending.
"""
@inline function _commodities_is_desc(
    commodities::AbstractVector{C}
) where {C<:LightCommodity}
    @inbounds for i in 2:length(commodities)
        commodities[i - 1].size < commodities[i].size && return false
    end
    return true
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

@inline function _check_oversize(largest_size::Real, cap::Real)
    largest_size > cap + 1e-8 && throw(
        DomainError(
            largest_size, "Commodity size $(largest_size) exceeds bin capacity $(cap)"
        ),
    )
    return nothing
end

"""
First-Fit-Decreasing placement loop. Walks `sizes_desc` (assumed sorted
descending), placing each into the first slot of `caps` with room, otherwise
opening a new slot with capacity `cap - s`. Mutates `caps` in place.
"""
@inline function _ffd_place!(caps::Vector{T}, sizes_desc, cap::T; eps=1e-8) where {T<:Real}
    @inbounds for s in sizes_desc
        placed = false
        for i in eachindex(caps)
            if caps[i] >= s - eps
                caps[i] -= s
                placed = true
                break
            end
        end
        placed || push!(caps, cap - s)
    end
    return caps
end

"""
First-Fit-Decreasing placement iterating a `Vector{C}` of commodities directly,
reading `c.size` per element. Equivalent to `_ffd_place!(caps, (c.size for c in items), cap)`
but type-stable (no `Base.Generator` boxing). `items` must be sorted descending by `.size`.
"""
@inline function _ffd_place_commodities!(
    caps::Vector{Float64}, items::AbstractVector{C}, cap::Float64; eps=1e-8
) where {C<:LightCommodity}
    @inbounds for c in items
        s = c.size
        placed = false
        for i in eachindex(caps)
            if caps[i] >= s - eps
                caps[i] -= s
                placed = true
                break
            end
        end
        placed || push!(caps, cap - s)
    end
    return caps
end

"""
First-Fit-Decreasing placement over the descending union of a pre-sorted
descending `Vector{Float64}` and a pre-sorted descending `Vector{C}` of
commodities. Mirror of `_ffd_place_merged!` that avoids materializing the
commodity sizes into a separate buffer.
"""
@inline function _ffd_place_merged_with_commodities!(
    caps::Vector{Float64},
    a::AbstractVector{Float64},
    b::AbstractVector{C},
    cap::Float64;
    eps=1e-8,
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
        placed = false
        for k in eachindex(caps)
            if caps[k] >= s - eps
                caps[k] -= s
                placed = true
                break
            end
        end
        placed || push!(caps, cap - s)
    end
    return caps
end

"""
First-Fit-Decreasing placement over the descending union of two pre-sorted
descending vectors `a` and `b` — uses a two-pointer merge to read the union
in descending order without materializing the merged vector. Equivalent to
`_ffd_place!(caps, merged, cap)` where `merged = sort(vcat(a, b); rev=true)`.
"""
@inline function _ffd_place_merged!(
    caps::Vector{T}, a::AbstractVector{T}, b::AbstractVector{T}, cap::T; eps=1e-8
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
        placed = false
        for k in eachindex(caps)
            if caps[k] >= s - eps
                caps[k] -= s
                placed = true
                break
            end
        end
        placed || push!(caps, cap - s)
    end
    return caps
end

"""
Best-Fit-Decreasing placement loop. Mirror of `_ffd_place!` for BFD.
"""
@inline function _bfd_place!(caps::Vector{T}, sizes_desc, cap::T; eps=1e-8) where {T<:Real}
    @inbounds for s in sizes_desc
        best_idx = 0
        best_left = typemax(T)
        for i in eachindex(caps)
            after = caps[i] - s
            if after >= -eps && after < best_left
                best_left = after
                best_idx = i
            end
        end
        if best_idx == 0
            push!(caps, cap - s)
        else
            caps[best_idx] -= s
        end
    end
    return caps
end

# Acquire the working caps vector: a buffer-owned one (cleared) or a fresh one.
@inline _take_caps(::Nothing) = Float64[]
@inline function _take_caps(buffer::BinPackingBuffer)
    empty!(buffer.remaining_capacities)
    return buffer.remaining_capacities
end

"""
Materializing First-Fit-Decreasing placement. Mirrors `_ffd_place!` but also
tracks per-bin commodity lists in `bin_contents`. Both vectors grow in lockstep
— `bin_contents[i]` holds the commodities placed in bin `i` (with remaining
capacity `caps[i]`). `sorted_commodities` must be descending by `.size`.
"""
@inline function _ffd_assign!(
    bin_contents::Vector{Vector{C}},
    caps::Vector{Float64},
    sorted_commodities,
    cap::Float64;
    eps=1e-8,
) where {C<:LightCommodity}
    @inbounds for c in sorted_commodities
        s = c.size
        placed = false
        for i in eachindex(caps)
            if caps[i] >= s - eps
                push!(bin_contents[i], c)
                caps[i] -= s
                placed = true
                break
            end
        end
        if !placed
            push!(bin_contents, [c])
            push!(caps, cap - s)
        end
    end
    return bin_contents
end

"""
Materializing Best-Fit-Decreasing placement. Mirror of `_ffd_assign!` for BFD.
"""
@inline function _bfd_assign!(
    bin_contents::Vector{Vector{C}},
    caps::Vector{Float64},
    sorted_commodities,
    cap::Float64;
    eps=1e-8,
) where {C<:LightCommodity}
    @inbounds for c in sorted_commodities
        s = c.size
        best_idx = 0
        best_left = Inf
        for i in eachindex(caps)
            after = caps[i] - s
            if after >= -eps && after < best_left
                best_left = after
                best_idx = i
            end
        end
        if best_idx == 0
            push!(bin_contents, [c])
            push!(caps, cap - s)
        else
            push!(bin_contents[best_idx], c)
            caps[best_idx] -= s
        end
    end
    return bin_contents
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
$TYPEDSIGNATURES

First-Fit-Decreasing bin count over `sizes_desc` (already sorted descending),
reusing `buffer.remaining_capacities`. Returns the number of bins. Allocates nothing in steady
state once `buffer.remaining_capacities` has grown to the working size.

!!! note
    `empty!` only resets the length to 0 without releasing the backing buffer,
    so `buffer.remaining_capacities` grows at most to the largest working size seen and never
    allocates after that.
"""
function ffd_count!(
    buffer::BinPackingBuffer{T}, bin_capacity::T, sizes_desc; eps=1e-8
) where {T<:Real}
    empty!(buffer.remaining_capacities)
    _ffd_place!(buffer.remaining_capacities, sizes_desc, bin_capacity; eps)
    return length(buffer.remaining_capacities)
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

`buffer.remaining_capacities` is reused as the scratch for the capacities copy.
`new` is iterated directly via `.size` accessors — it MUST be sorted descending by
`.size` (an invariant enforced via `@boundscheck`, stripped in release builds).
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

    empty!(buffer.remaining_capacities)
    for b in existing_bins
        push!(buffer.remaining_capacities, b.remaining_capacity)
    end
    n_frozen = length(buffer.remaining_capacities)

    _ffd_place_commodities!(buffer.remaining_capacities, new, bin_capacity)
    return length(buffer.remaining_capacities) - n_frozen
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
    _check_oversize(sorted_new[1].size, bin_capacity)
    for c in sorted_new
        placed = false
        @inbounds for i in eachindex(bins)
            if bins[i].remaining_capacity >= c.size - 1e-8
                push!(bins[i].commodities, c)
                bins[i].remaining_capacity -= c.size
                placed = true
                break
            end
        end
        if !placed
            push!(bins, Bin([c], bin_capacity - c.size))
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
    sorted_commodities =
        presorted ? commodities : sort(commodities; by=c -> c.size, rev=true)
    cap = Float64(arc_f.bin_capacity)
    _check_oversize(sorted_commodities[1].size, cap)

    bin_contents = Vector{C}[]
    bin_rem_caps = Float64[]
    _ffd_assign!(bin_contents, bin_rem_caps, sorted_commodities, cap)

    return [Bin(bin_contents[i], bin_rem_caps[i]) for i in eachindex(bin_contents)]
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

Pass `buffer` to reuse a `BinPackingBuffer`'s `caps` vector and avoid the
per-call allocation; otherwise a fresh `Vector{Float64}` is used.

Throws `DomainError` if any commodity exceeds `arc_f.bin_capacity`.
"""
function tentative_bin_count(
    arc_f::BinPackingArcCost,
    commodities::Vector{C};
    presorted::Bool=false,
    buffer::Union{Nothing,BinPackingBuffer}=nothing,
) where {C<:LightCommodity}
    isempty(commodities) && return 0
    cap = Float64(arc_f.bin_capacity)
    caps = _take_caps(buffer)
    if presorted
        _check_oversize(commodities[1].size, cap)
        _ffd_place!(caps, (c.size for c in commodities), cap)
    else
        sorted_sizes = sort([c.size for c in commodities]; rev=true)
        _check_oversize(sorted_sizes[1], cap)
        _ffd_place!(caps, sorted_sizes, cap)
    end
    return length(caps)
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

Pass `buffer` to reuse a `BinPackingBuffer`'s `caps` vector and avoid the
per-call allocation; otherwise a fresh `Vector{Float64}` is used.

Throws `DomainError` if any commodity exceeds `arc_f.bin_capacity`.
"""
function tentative_best_fit_count(
    arc_f::BinPackingArcCost,
    commodities::Vector{C};
    presorted::Bool=false,
    buffer::Union{Nothing,BinPackingBuffer}=nothing,
) where {C<:LightCommodity}
    isempty(commodities) && return 0
    cap = Float64(arc_f.bin_capacity)
    caps = _take_caps(buffer)
    if presorted
        _check_oversize(commodities[1].size, cap)
        _bfd_place!(caps, (c.size for c in commodities), cap)
    else
        sorted_sizes = sort([c.size for c in commodities]; rev=true)
        _check_oversize(sorted_sizes[1], cap)
        _bfd_place!(caps, sorted_sizes, cap)
    end
    return length(caps)
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
    cap = Float64(arc_f.bin_capacity)
    _check_oversize(sorted_commodities[1].size, cap)

    bin_contents = Vector{C}[]
    bin_rem_caps = Float64[]
    _bfd_assign!(bin_contents, bin_rem_caps, sorted_commodities, cap)

    return [Bin(bin_contents[i], bin_rem_caps[i]) for i in eachindex(bin_contents)]
end
