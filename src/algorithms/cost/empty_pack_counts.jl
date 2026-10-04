"""
$TYPEDEF

FFD bin count of one order's commodities on an empty arc, for each distinct bin
capacity of a set of arcs. The count only depends on the order and the capacity,
so it is computed once and reused on every empty arc instead of repacking.

# Fields
$TYPEDFIELDS
"""
struct EmptyPackCounts
    "distinct bin capacities, shared by all orders of a bundle"
    capacities::Vector{Float64}
    "FFD bin count of the order for each capacity"
    counts::Vector{Int}
end

# Bin count of `ec` for capacity `cap`, or -1 if `cap` was not precomputed.
@inline function _empty_bin_count(ec::EmptyPackCounts, cap::Float64)
    @inbounds for i in eachindex(ec.capacities)
        ec.capacities[i] == cap && return ec.counts[i]
    end
    return -1
end

_collect_bin_capacities!(caps::Vector{Float64}, ::AbstractArcCostFunction) = caps
function _collect_bin_capacities!(caps::Vector{Float64}, c::BinPackingArcCost)
    cap = Float64(c.bin_capacity)
    cap in caps || push!(caps, cap)
    return caps
end
function _collect_bin_capacities!(caps::Vector{Float64}, c::SumArcCost)
    for t in c.terms
        _collect_bin_capacities!(caps, t)
    end
    return caps
end
function _collect_bin_capacities!(caps::Vector{Float64}, arc::NetworkArc)
    return _collect_bin_capacities!(caps, arc.cost)
end
function _collect_bin_capacities!(caps::Vector{Float64}, arc::MultiModalArc)
    for mode in arc.modes
        _collect_bin_capacities!(caps, mode.cost)
    end
    return caps
end

"""
$TYPEDSIGNATURES

One [`EmptyPackCounts`](@ref) per order of `bundle`, for the bin capacities found on
`bundle_arcs`. Meant for a virtual merged bundle, whose orders hold thousands of
commodities and are priced on many empty arcs. Pass the result as `empty_counts`
to `update_bundle_cost_matrix!`.
"""
function empty_pack_counts(instance::Instance, bundle::Bundle, bundle_arcs)
    cache = instance.index_cache
    caps = Float64[]
    for (u, v) in bundle_arcs
        arc = ttg_edge_arc(cache, u, v)
        isnothing(arc) || _collect_bin_capacities!(caps, arc)
    end
    buffer = BinPackingBuffer()
    return map(bundle.orders) do order
        counts = map(caps) do cap
            empty!(buffer.remaining_capacities)
            _ffd_place_commodities!(buffer.remaining_capacities, order.commodities, cap)
            return length(buffer.remaining_capacities)
        end
        return EmptyPackCounts(caps, counts)
    end
end

"""
$TYPEDSIGNATURES

Incremental cost of packing `new` on an empty arc. With an [`EmptyPackCounts`](@ref)
(last argument), bin-packing terms read the precomputed FFD bin count instead of
repacking (same value, same term order for `SumArcCost`). `new` must then be exactly
the commodities of the order the counts were built for.
Without it, this is `incremental_cost!` on `nothing`.
"""
function empty_incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::AbstractArcCostFunction,
    new::Vector{<:LightCommodity},
    ::Union{Nothing,EmptyPackCounts},
)
    return incremental_cost!(buffer, arc_f, nothing, new)
end

function empty_incremental_cost!(
    buffer::BinPackingBuffer,
    arc_f::BinPackingArcCost,
    new::Vector{<:LightCommodity},
    ec::EmptyPackCounts,
)
    isempty(new) && return 0.0
    n = _empty_bin_count(ec, Float64(arc_f.bin_capacity))
    n < 0 && return incremental_cost!(buffer, arc_f, nothing, new)
    return arc_f.cost_per_bin * n
end

@inline _sum_empty_cost(::BinPackingBuffer, ::Tuple{}, ::Vector{<:LightCommodity}, _) = 0.0
@inline function _sum_empty_cost(
    buffer::BinPackingBuffer, terms::Tuple, new::Vector{<:LightCommodity}, ec
)
    return empty_incremental_cost!(buffer, first(terms), new, ec) +
           _sum_empty_cost(buffer, Base.tail(terms), new, ec)
end

function empty_incremental_cost!(
    buffer::BinPackingBuffer,
    c::SumArcCost,
    new::Vector{<:LightCommodity},
    ec::Union{Nothing,EmptyPackCounts},
)
    return _sum_empty_cost(buffer, c.terms, new, ec)
end
