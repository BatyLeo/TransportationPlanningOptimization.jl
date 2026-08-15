"""
$TYPEDEF

A solution to the network design optimization problem.
It stores the chosen paths for each bundle in the `TravelTimeGraph` and precomputes
key metrics such as commodity distributions on arcs and individual arc costs.

# Fields
$TYPEDFIELDS
"""
struct Solution{C<:LightCommodity}
    "Paths for each bundle in the instance. `bundle_paths[i]` is a sequence of node codes in the
    `TravelTimeGraph` for the i-th bundle."
    bundle_paths::Vector{Vector{Int}}
    "Per-edge assignment, keyed by time-space graph codes `(u_tsg_code, v_tsg_code)`.
    Values are `SingleAssignment{C}` for single-mode edges and `MultiAssignment{C}` for multi-modal
    edges."
    assignments::Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}
end

function Base.show(io::IO, sol::Solution)
    nb_trucks = sum(_bin_count(a) for a in values(sol.assignments); init=0)
    return print(io, "Solution(num_trucks=$(nb_trucks), cost=$(cost(sol)))")
end

"""
$TYPEDSIGNATURES

Initialize an empty solution for the given instance.
"""
function Solution(instance::Instance{Bundle{Order{IDA,I}}}) where {IDA,I}
    C = LightCommodity{I}
    return Solution{C}(
        [Int[] for _ in 1:bundle_count(instance)],
        Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}(),
    )
end

"""
$TYPEDSIGNATURES

Compute the cost of the solution by summing individual arc costs.
"""
function cost(sol::Solution)
    return sum(cost_of(a) for a in values(sol.assignments); init=0.0)
end
