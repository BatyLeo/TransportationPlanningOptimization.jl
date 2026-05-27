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

function evaluate(c::SumArcCost, comms::Vector{<:LightCommodity})
    return sum(evaluate(t, comms) for t in c.terms)
end

function incremental_cost(
    c::SumArcCost, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return sum(incremental_cost(t, existing, new) for t in c.terms)
end

function lower_bound_incremental_cost(
    c::SumArcCost, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    return sum(lower_bound_incremental_cost(t, existing, new) for t in c.terms)
end

# The buffer-threaded `incremental_cost!(::BinPackingBuffer, ::SumArcCost, ...)`
# forwarding overload lives in `algorithms/cost_matrix_update.jl`, which is
# included after `instance/bin.jl` defines `BinPackingBuffer`.

function compute_bin_assignments(c::SumArcCost, comms::Vector{<:LightCommodity})
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError("compute_bin_assignments: SumArcCost has no BinPackingArcCost term"),
    )
    return compute_bin_assignments(bp, comms)
end

function compute_bin_assignments_bfd(c::SumArcCost, comms::Vector{<:LightCommodity})
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError(
            "compute_bin_assignments_bfd: SumArcCost has no BinPackingArcCost term"
        ),
    )
    return compute_bin_assignments_bfd(bp, comms)
end

function tentative_bin_count(c::SumArcCost, comms::Vector{<:LightCommodity})
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError("tentative_bin_count: SumArcCost has no BinPackingArcCost term")
    )
    return tentative_bin_count(bp, comms)
end

function tentative_best_fit_count(c::SumArcCost, comms::Vector{<:LightCommodity})
    bp = _find_bin_packing(c)
    bp === nothing && throw(
        ArgumentError("tentative_best_fit_count: SumArcCost has no BinPackingArcCost term"),
    )
    return tentative_best_fit_count(bp, comms)
end
