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

Evaluate the cost of transporting a list of commodities on an arc with a bin-packing cost
function. The cost is based on the number of bins (trucks) needed to transport all
commodities. Uses the First-Fit Decreasing (FFD) heuristic to determine bin assignments and
count.
"""
function evaluate(
    arc_f::BinPackingArcCost, commodities::Vector{<:LightCommodity}; presorted::Bool=false
)
    return arc_f.cost_per_bin * tentative_bin_count(arc_f, commodities; presorted)
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

Mirror of `tentative_bin_count` for the BFD heuristic.

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

Compute the bin assignments for `commodities` using Best-Fit Decreasing
(BFD). Returns a vector of `Bin` objects.

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
