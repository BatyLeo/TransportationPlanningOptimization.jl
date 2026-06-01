"""
$TYPEDEF

Composite arc cost that sums multiple `AbstractArcCostFunction` terms on a
single arc. `evaluate`, `incremental_cost`, and `lower_bound_incremental_cost`
forward as sums over `terms`.

Bin-packing methods (`compute_bin_assignments`, `tentative_bin_count`,
`tentative_best_fit_count`, `compute_bin_assignments_bfd`) require exactly one
term to be a `BinPackingArcCost` and dispatch to it. Use a single term (not a
`SumArcCost`) when there is only one cost component.

Tuple-typed `terms` so each `SumArcCost{Tuple{BinPackingArcCost,...}}`
specializes for type stability.

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

"""
$TYPEDSIGNATURES

Return the unique `BinPackingArcCost` term inside `c.terms`, or `nothing` if
no such term exists. Throws `ArgumentError` if more than one is present
(ambiguous bin-packing semantics).
"""
function _find_bin_packing(c::SumArcCost)
    bps = filter(t -> t isa BinPackingArcCost, c.terms)
    length(bps) > 1 && throw(
        ArgumentError(
            "SumArcCost has $(length(bps)) BinPackingArcCost terms, expected at most 1"
        ),
    )
    return isempty(bps) ? nothing : only(bps)
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

@inline _sum_incremental_cost(
    ::Tuple{}, ::Vector{C}, ::Vector{C}
) where {C<:LightCommodity} = 0.0
@inline function _sum_incremental_cost(
    terms::Tuple, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return incremental_cost(first(terms), existing, new) +
           _sum_incremental_cost(Base.tail(terms), existing, new)
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

Evaluate the sum of `c.terms` on `comms`. If `presorted=true`, assumes `comms` are
pre-sorted in non-increasing order of size for bin-packing purposes, which can speed up
evaluation when `c.terms` includes a `BinPackingArcCost`.
"""
function evaluate(
    c::SumArcCost, comms::Vector{C}; presorted::Bool=false
) where {C<:LightCommodity}
    return _sum_evaluate(c.terms, comms, presorted)
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

# The buffer-threaded `incremental_cost!(::BinPackingBuffer, ::SumArcCost, ...)`
# forwarding overload lives in `algorithms/cost_matrix_update.jl`, which is
# included after `instance/bin.jl` defines `BinPackingBuffer`.

function compute_bin_assignments(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError("compute_bin_assignments: SumArcCost has no BinPackingArcCost term"),
    )
    return compute_bin_assignments(bp, comms; presorted)
end

function compute_bin_assignments_bfd(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError(
            "compute_bin_assignments_bfd: SumArcCost has no BinPackingArcCost term"
        ),
    )
    return compute_bin_assignments_bfd(bp, comms; presorted)
end

function tentative_bin_count(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError("tentative_bin_count: SumArcCost has no BinPackingArcCost term")
    )
    return tentative_bin_count(bp, comms; presorted)
end

function tentative_best_fit_count(
    c::SumArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError("tentative_best_fit_count: SumArcCost has no BinPackingArcCost term"),
    )
    return tentative_best_fit_count(bp, comms; presorted)
end
