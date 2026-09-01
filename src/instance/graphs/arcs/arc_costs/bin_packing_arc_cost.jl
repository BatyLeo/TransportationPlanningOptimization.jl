"""
$TYPEDEF

A bin-packing (or step) cost function. A fixed cost is incurred for each bin/truck needed.

# Fields
$TYPEDFIELDS
"""
struct BinPackingArcCost <: AbstractArcCostFunction
    "fixed cost for each bin used (e.g., cost per truck)"
    cost_per_bin::Float64
    "capacity of a single bin/truck"
    bin_capacity::Int
end

"""
$TYPEDSIGNATURES

Compute the bin assignments for a list of commodities using the First-Fit Decreasing heuristic.
Returns a vector of `Bin` objects.
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
under `arc_f`, without allocating any `Bin` object.

Prefer this over `compute_bin_assignments` whenever only the bin count is
needed. Use `compute_bin_assignments` when the actual bin contents are needed downstream.

Pass `buffer` to reuse a `BinPackingBuffer`'s `caps` vector and avoid the
per-call allocation, otherwise a fresh `Vector{Float64}` is used.

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
    caps = _init_remaining_capacities(buffer)
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

Compute the bin assignments for `commodities` using Best-Fit Decreasing.
Returns a vector of `Bin` objects.

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

"""
$TYPEDSIGNATURES

Mirror of `tentative_bin_count` for the BFD heuristic.

Pass `buffer` to reuse a `BinPackingBuffer`'s `caps` vector and avoid the
per-call allocation, otherwise a fresh `Vector{Float64}` is used.

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
    caps = _init_remaining_capacities(buffer)
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

Uses the First-Fit Decreasing (FFD) heuristic to determine bin assignments and count.
"""
function evaluate(
    arc_f::BinPackingArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    return arc_f.cost_per_bin * tentative_bin_count(arc_f, commodities; presorted)
end

"""
$TYPEDSIGNATURES

Buffer-threaded FFD bin cost on an empty arc. Places `new` from scratch.
"""
function incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    ::Nothing,
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    isempty(new) && return 0.0
    @boundscheck _commodities_is_desc(new) ||
        throw(ArgumentError("`new` must be sorted descending by `.size`"))
    cap = Float64(arc_f.bin_capacity)
    empty!(buffer.remaining_capacities)
    _ffd_place_commodities!(buffer.remaining_capacities, new, cap)
    return arc_f.cost_per_bin * length(buffer.remaining_capacities)
end

"""
$TYPEDSIGNATURES

Buffer-threaded FFD bin cost of adding `new` to `existing`.
Streams a descending two-way merge of the two pre-sorted runs into FFD
without materializing the union vector.
When `n_existing >= 0`, the standalone FFD-on-existing pass is skipped and
the cached bin count is used instead.
"""
function incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    isempty(new) && return 0.0
    @boundscheck _commodities_is_desc(new) ||
        throw(ArgumentError("`new` must be sorted descending by `.size`"))
    cap = Float64(arc_f.bin_capacity)

    # Existing run sizes, descending, materialized into `existing_sizes` so the
    # merge's hot loop reads from a tightly packed `Vector{Float64}`.
    @boundscheck _commodities_is_desc(existing) ||
        throw(ArgumentError("`existing` must be sorted descending by `.size`"))
    resize!(buffer.existing_sizes, length(existing))
    @inbounds for (i, c) in enumerate(existing)
        buffer.existing_sizes[i] = c.size
    end

    # When the caller passes `n_existing` (= `length(assignment.bins)`),
    # skip the standalone FFD-on-existing pass and trust the cached value.
    n_ex = if n_existing >= 0
        n_existing
    else
        ffd_count!(buffer, cap, buffer.existing_sizes)
    end

    # FFD over the descending union of `existing_sizes` and `new`.
    empty!(buffer.remaining_capacities)
    _ffd_place_merged_with_commodities!(
        buffer.remaining_capacities, buffer.existing_sizes, new, cap
    )
    n_union = length(buffer.remaining_capacities)

    return arc_f.cost_per_bin * (n_union - n_ex)
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental cost: first-fit `new` onto the committed bins without
re-packing. Returns `cost_per_bin * (newly opened bins)`.
`existing_comms` and `new_total_size` are accepted for signature uniformity
with the generic fallback but ignored (bin packing works on bins directly).
"""
function frozen_incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    existing_bins::AbstractVector{<:Bin},
    ::Vector{C},
    new::Vector{C},
    ::Float64=NaN,
) where {C<:LightCommodity}
    isempty(new) && return 0.0
    cap = Float64(arc_f.bin_capacity)
    n_new = frozen_incremental_count!(buffer, cap, existing_bins, new)
    return arc_f.cost_per_bin * n_new
end

"""
$TYPEDSIGNATURES

Lower bound using fractional bin counts (continuous relaxation of FFD).
"""
function lower_bound_incremental_cost(
    arc_f::BinPackingArcCost, ::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    # (existing + new) / cap - existing / cap = new / cap
    new_size = sum(c.size for c in new_commodities; init=0.0)
    return arc_f.cost_per_bin * new_size / arc_f.bin_capacity
end
