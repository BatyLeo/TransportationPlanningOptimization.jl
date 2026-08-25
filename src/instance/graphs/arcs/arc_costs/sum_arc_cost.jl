"""
$TYPEDEF

Composite arc cost that sums multiple `AbstractArcCostFunction` terms on a
single arc. `evaluate`, `incremental_cost`, and `lower_bound_incremental_cost`
forward as sums over `terms`.

Bin-packing methods (`compute_bin_assignments`, `tentative_bin_count`,
`tentative_best_fit_count`, `compute_bin_assignments_bfd`) require exactly one
term to be a `BinPackingArcCost` and dispatch to it. Use a single term (not a
`SumArcCost`) when there is only one cost component.

# Fields
$TYPEDFIELDS
"""
struct SumArcCost{T<:Tuple} <: AbstractArcCostFunction
    "tuple of `AbstractArcCostFunction` instances summed at evaluation time"
    terms::T
    function SumArcCost(terms::Tuple{Vararg{AbstractArcCostFunction}})
        isempty(terms) && throw(ArgumentError("SumArcCost: terms tuple cannot be empty"))
        return new{typeof(terms)}(terms)
    end
end

# Type-stable tuple recursion for summing `evaluate`, `incremental_cost`,
# and `lower_bound_incremental_cost`.
@inline _sum_evaluate(::Tuple{}, ::Vector{C}, ::Bool) where {C<:LightCommodity} = 0.0
@inline function _sum_evaluate(
    terms::Tuple, comms::Vector{C}, presorted::Bool
) where {C<:LightCommodity}
    return evaluate(first(terms), comms; presorted) +
           _sum_evaluate(Base.tail(terms), comms, presorted)
end

"""
$TYPEDSIGNATURES

Evaluate the sum of `c.terms` on `comms`. If `presorted=true`, assumes `comms` are
pre-sorted in non-increasing order of size for bin-packing purposes, which can speed up
evaluation when `c.terms` includes a `BinPackingArcCost`.
"""
function evaluate(
    c::SumArcCost, comms::Vector{C}; presorted::Bool=false
) where {C<:LightCommodity}
    return _sum_evaluate(c.terms, comms, presorted)
end

@inline _sum_incremental_cost(
    ::Tuple{}, ::Vector{C}, ::Vector{C}
) where {C<:LightCommodity} = 0.0
@inline function _sum_incremental_cost(
    terms::Tuple, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return incremental_cost(first(terms), existing, new) +
           _sum_incremental_cost(Base.tail(terms), existing, new)
end

"""
$TYPEDSIGNATURES

Return the incremental cost of adding `new` commodities to an arc with existing commodities
`existing`, as the sum of incremental costs over `c.terms`.
"""
function incremental_cost(
    c::SumArcCost, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return _sum_incremental_cost(c.terms, existing, new)
end

@inline _sum_lb_incremental_cost(
    ::Tuple{}, ::Vector{C}, ::Vector{C}
) where {C<:LightCommodity} = 0.0
@inline function _sum_lb_incremental_cost(
    terms::Tuple, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return lower_bound_incremental_cost(first(terms), existing, new) +
           _sum_lb_incremental_cost(Base.tail(terms), existing, new)
end

"""
$TYPEDSIGNATURES

Return the incremental lower bound cost of adding `new` commodities to an arc with existing
commodities `existing`, as the sum of incremental lower bound costs over `c.terms`.
"""
function lower_bound_incremental_cost(
    c::SumArcCost, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return _sum_lb_incremental_cost(c.terms, existing, new)
end

"""
$TYPEDSIGNATURES

Return the unique [`BinPackingArcCost`](@ref) term inside `c.terms`, or
`nothing` if none is present. Throws `ArgumentError` if more than one is present.
"""
function _try_find_bin_packing(c::SumArcCost)
    bps = filter(t -> t isa BinPackingArcCost, c.terms)
    length(bps) > 1 && throw(
        ArgumentError(
            "SumArcCost has $(length(bps)) BinPackingArcCost terms, expected at most 1"
        ),
    )
    return isempty(bps) ? nothing : only(bps)
end

"""
$TYPEDSIGNATURES

Return the unique [`BinPackingArcCost`](@ref) term inside `c.terms`.
Throws `ArgumentError` if zero or more than one `BinPackingArcCost` is present.
"""
function _find_bin_packing(c::SumArcCost)
    bp = _try_find_bin_packing(c)
    bp === nothing && throw(ArgumentError("SumArcCost has no BinPackingArcCost term"))
    return bp
end

function compute_bin_assignments(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    return compute_bin_assignments(_find_bin_packing(c), comms; presorted)
end

function compute_bin_assignments_bfd(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    return compute_bin_assignments_bfd(_find_bin_packing(c), comms; presorted)
end

function tentative_bin_count(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    return tentative_bin_count(_find_bin_packing(c), comms; presorted)
end

function tentative_best_fit_count(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    return tentative_best_fit_count(_find_bin_packing(c), comms; presorted)
end

@inline _sum_incremental_cost_buf(
    ::BinPackingBuffer, ::Tuple{}, ::Vector{C}, ::Vector{C}, ::Int
) where {C<:LightCommodity} = 0.0
@inline _sum_incremental_cost_buf(
    ::BinPackingBuffer, ::Tuple{}, ::Nothing, ::Vector{<:LightCommodity}, ::Int
) = 0.0
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
@inline function _sum_incremental_cost_buf(
    buffer::BinPackingBuffer,
    terms::Tuple,
    ::Nothing,
    new::Vector{<:LightCommodity},
    n_existing::Int,
)
    return incremental_cost!(buffer, first(terms), nothing, new; n_existing) +
           _sum_incremental_cost_buf(buffer, Base.tail(terms), nothing, new, n_existing)
end

"""
$TYPEDSIGNATURES

Buffer-threaded `incremental_cost!` for `SumArcCost`.
Sums per-term incremental costs, forwarding the shared `buffer` to each term.
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

function incremental_cost!(
    buffer::BinPackingBuffer,
    c::SumArcCost,
    ::Nothing,
    new::Vector{<:LightCommodity};
    n_existing::Int=-1,
)
    return _sum_incremental_cost_buf(buffer, c.terms, nothing, new, n_existing)
end

"""
$TYPEDSIGNATURES

Frozen-bin incremental cost for `SumArcCost`. Dispatches uniformly to each
term's `frozen_incremental_cost!` (bin-packing terms use the frozen bins,
others fall back to `incremental_cost_with_size` or `incremental_cost!`).
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
        total += frozen_incremental_cost!(
            buffer, t, existing_bins, existing_comms, new, new_total_size
        )
    end
    return total
end
