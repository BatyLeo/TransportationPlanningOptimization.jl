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

"""
$TYPEDSIGNATURES

If `largest_size` exceeds `cap`, throw a `DomainError`.
"""
@inline function _check_oversize(largest_size::Real, cap::Real; eps=EPS)
    if largest_size > cap + eps
        throw(
            DomainError(
                largest_size, "Commodity size $(largest_size) exceeds bin capacity $(cap)"
            ),
        )
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Return the index of the first bin in `remaining_capacities` that can fit an
item of size `s`, or `0` if none can.
"""
@inline function _first_fit_index(remaining_capacities, s; eps=EPS)
    @inbounds for i in eachindex(remaining_capacities)
        if s <= remaining_capacities[i] + eps
            return i
        end
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
