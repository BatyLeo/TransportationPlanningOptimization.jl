"""
$TYPEDSIGNATURES

Compute the additional cost of adding `new_commodities` to an arc that already contains
`existing_commodities`.
"""
function incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    # Default implementation: evaluate total and subtract
    all_commodities = vcat(existing_commodities, new_commodities)
    return evaluate(arc_f, all_commodities) - evaluate(arc_f, existing_commodities)
end

"""
$TYPEDSIGNATURES

Specialized for LinearArcCost for efficiency.
"""
function incremental_cost(
    arc_f::LinearArcCost, ::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    total_new_size = sum(c.size for c in new_commodities; init=0.0)
    return arc_f.cost_per_unit_size * total_new_size
end

"""
$TYPEDSIGNATURES

Buffer-threaded variant of `incremental_cost`. The generic fallback ignores the
buffer and forwards to `incremental_cost`, so `LinearArcCost`, node costs, and
any other cheap cost function need no specialization. Only `BinPackingArcCost`
(and `SumArcCost`, which forwards to its unique bin-packing term) specialize
this to reuse the scratch buffer and avoid per-call allocation.
"""
function incremental_cost!(
    ::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing, new)
end

"""
$TYPEDSIGNATURES

Buffer-threaded variant of `incremental_cost` for node costs. Node costs are
cheap, so the buffer is ignored and the call forwards to `incremental_cost`.
"""
function incremental_cost!(
    ::BinPackingBuffer,
    node_f::AbstractNodeCostFunction,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return incremental_cost(node_f, existing, new)
end

"""
$TYPEDSIGNATURES

Return `true` if `v` is sorted in non-increasing (descending) order. Used to
skip a redundant `sort!` when a size run is already descending (the common case
once `Order.commodities` is pre-sorted at instance construction).
"""
function _is_desc(v::AbstractVector{Float64})
    @inbounds for i in 2:length(v)
        v[i - 1] < v[i] && return false
    end
    return true
end

"""
$TYPEDSIGNATURES

Incremental FFD bin cost of adding `new` to `existing` on a `BinPackingArcCost`
arc, reusing `buffer`. Equals `cost_per_bin * (FFD(existing union new) -
FFD(existing))`, identical to the generic fallback and to the sort-the-union
form, but it streams the descending two-way merge of the two runs into FFD
without materializing the union vector.

`Order.commodities` is kept sorted by size descending at instance construction
(see `build_instance`), so both the per-edge `new` run (one order's commodities
in the common case) and the `existing` run arrive pre-sorted. `new` is still
checked and sorted in place if needed (the `new_sizes` buffer slot doubles as
that scratch). `existing` is iterated lazily — when the descending invariant
holds, the loop iterates the commodity vector directly; otherwise a one-shot
sort over a fresh `Vector{Float64}` is taken (rare).
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

    # Existing run sizes, descending — materialized into `existing_sizes` so the
    # merge's hot loop reads from a tightly packed `Vector{Float64}`. Validated
    # against the descending invariant in debug builds.
    if isempty(existing)
        empty!(buffer.existing_sizes)
    else
        @boundscheck _commodities_is_desc(existing) ||
            throw(ArgumentError("`existing` must be sorted descending by `.size`"))
        resize!(buffer.existing_sizes, length(existing))
        @inbounds for (i, c) in enumerate(existing)
            buffer.existing_sizes[i] = c.size
        end
    end

    # When the caller passes `n_existing` (= `length(assignment.bins)`),
    # skip the standalone FFD-on-existing pass and trust the cached value.
    n_ex = if n_existing >= 0
        n_existing
    elseif isempty(existing)
        0
    else
        ffd_count!(buffer, cap, buffer.existing_sizes)
    end

    # FFD over the descending union of `existing_sizes` and `new`. The `new`
    # commodity vector is iterated directly via `c.size` — no `new_sizes`
    # scratch needed.
    empty!(buffer.remaining_capacities)
    _ffd_place_merged_with_commodities!(
        buffer.remaining_capacities, buffer.existing_sizes, new, cap
    )
    n_union = length(buffer.remaining_capacities)

    return arc_f.cost_per_bin * (n_union - n_ex)
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental cost of adding `new` onto the already committed bins
`existing_bins` on a `BinPackingArcCost` arc, reusing `buffer`. Equals
`cost_per_bin * (number of bins newly opened by first-fitting `new` onto the
frozen bins' remaining capacities)`. This is the STP packing semantics: the
committed bins are never re-packed and never re-sorted, only `new` is dropped
in via first-fit. Used under `packing == :frozen`.
"""
function frozen_incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    existing_bins::AbstractVector{<:Bin},
    new::Vector{C},
) where {C<:LightCommodity}
    isempty(new) && return 0.0
    cap = Float64(arc_f.bin_capacity)
    n_new = frozen_incremental_count!(buffer, cap, existing_bins, new)
    return arc_f.cost_per_bin * n_new
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental cost for `SumArcCost`. The unique `BinPackingArcCost`
term uses the frozen count against `existing_bins`. Every other term (carbon,
stock, etc.) is linear in volume, so its incremental cost is identical in both
packing modes and is computed against `existing_comms` via the plain
`incremental_cost`. The bin-packing term is excluded from that sum and replaced
by the frozen count, keeping the result consistent with the frozen commit.
"""
function frozen_incremental_cost!(
    buffer::BinPackingBuffer,
    c::SumArcCost,
    existing_bins::AbstractVector{<:Bin},
    existing_comms::Vector{C},
    new::Vector{C},
    new_total_size::Float64=NaN,
) where {C<:LightCommodity}
    total = 0.0
    for t in c.terms
        if t isa BinPackingArcCost
            total += frozen_incremental_cost!(buffer, t, existing_bins, new)
        elseif !isnan(new_total_size)
            total += incremental_cost_with_size(t, existing_comms, new, new_total_size)
        else
            total += incremental_cost!(buffer, t, existing_comms, new)
        end
    end
    return total
end

"""
$TYPEDSIGNATURES

Buffer-threaded `incremental_cost!` for `SumArcCost`. Sums the per-term
incremental costs, forwarding the shared `buffer` to each term. The unique
`BinPackingArcCost` term reuses the buffer (its `incremental_cost!`
specialization), every other term falls back to its plain `incremental_cost`
through the generic `incremental_cost!`. The result is identical to the
sum-over-terms `incremental_cost(::SumArcCost, ...)`.
"""
function incremental_cost!(
    buffer::BinPackingBuffer,
    c::SumArcCost,
    existing::Vector{C},
    new::Vector{C};
    n_existing::Int=-1,
) where {C<:LightCommodity}
    return _sum_incremental_cost_buf(buffer, c.terms, existing, new, n_existing)
end
@inline _sum_incremental_cost_buf(
    ::BinPackingBuffer, ::Tuple{}, ::Vector{C}, ::Vector{C}, ::Int
) where {C<:LightCommodity} = 0.0
@inline function _sum_incremental_cost_buf(
    buffer::BinPackingBuffer,
    terms::Tuple,
    existing::Vector{C},
    new::Vector{C},
    n_existing::Int,
) where {C<:LightCommodity}
    return incremental_cost!(buffer, first(terms), existing, new; n_existing) +
           _sum_incremental_cost_buf(buffer, Base.tail(terms), existing, new, n_existing)
end

"""
$TYPEDSIGNATURES

Fast path for cost functions whose incremental cost depends only on the total
size of the new commodities (not on individual commodity attributes or on the
existing commodities). When `new_total_size` is available (passed from
`order.total_size`), subtypes can return the cost in O(1) without iterating
the commodity vector.

The default falls back to `incremental_cost`, ignoring `new_total_size`.
Specialize this for any `AbstractArcCostFunction` or `AbstractNodeCostFunction`
whose incremental cost is a function of the new total size alone (e.g. linear
cost functions like `CarbonArcCost`, `NodeVolumeCost`).
"""
function incremental_cost_with_size(
    arc_f::AbstractArcCostFunction, existing::Vector{C}, new::Vector{C}, ::Float64
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing, new)
end

function incremental_cost_with_size(
    arc_f::LinearArcCost, ::Vector{C}, ::Vector{C}, new_total_size::Float64
) where {C<:LightCommodity}
    return arc_f.cost_per_unit_size * new_total_size
end

function incremental_cost_with_size(
    node_f::AbstractNodeCostFunction, existing::Vector{C}, new::Vector{C}, ::Float64
) where {C<:LightCommodity}
    return incremental_cost(node_f, existing, new)
end

"""
$TYPEDSIGNATURES

Lower-bound variant of `incremental_cost`. By default it forwards to
`incremental_cost`, so any new `AbstractArcCostFunction` subtype automatically
inherits a sane default. Specialize this for cost functions whose lower bound
differs from their actual cost (for example, `BinPackingArcCost`).
"""
function lower_bound_incremental_cost(
    arc_f::AbstractArcCostFunction,
    existing_commodities::Vector{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    return incremental_cost(arc_f, existing_commodities, new_commodities)
end

"""
$TYPEDSIGNATURES

Lower-bound cost on a `BinPackingArcCost` arc using fractional bin counts
(no ceiling). The result is a continuous relaxation of the FFD cost. It is
not the cheapest path for an actual solver, but it is a valid lower bound
when summed across paths and used for filtering.
"""
function lower_bound_incremental_cost(
    arc_f::BinPackingArcCost, ::Vector{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    # (existing + new) / cap - existing / cap = new / cap
    new_size = sum(c.size for c in new_commodities; init=0.0)
    return arc_f.cost_per_bin * new_size / arc_f.bin_capacity
end
