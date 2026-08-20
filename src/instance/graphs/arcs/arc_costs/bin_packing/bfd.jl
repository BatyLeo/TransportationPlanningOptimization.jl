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
