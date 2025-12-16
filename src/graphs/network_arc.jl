# network garph should be a multigraph, transformed into a simple graph for time space an travel time graphs
# MixedArcCostFunction

# ideally, non decreasing with size
abstract type AbstractArcCostFunction end

struct LinearArcCost <: AbstractArcCostFunction
    cost_per_unit_size::Float64
end

struct BinPackingArcCost <: AbstractArcCostFunction
    cost_per_bin::Float64
    bin_capacity::Int
end
# algebraic data types
# multi criteria
struct VectorPackingArcCost <: AbstractArcCostFunction end

# grid: discretized km, m3, kg -> cost per m3
struct GridLinearArcCost <: AbstractArcCostFunction end

# cout arc de douane (qui passe par un point de douane)

"""
$TYPEDEF

Representation of an arc in the network graph.

# Fields
$TYPEDFIELDS
"""
@kwdef struct NetworkArc{C<:AbstractArcCostFunction,K}
    "id of the origin node"
    origin_id::String
    "id of the destination node"
    destination_id::String
    "travel time in number of discrete time steps (0 if less than the time discretization step)"
    travel_time::Int
    "capacity of the arc (in size units)"
    capacity::Int = typemax(Int)
    "cost function associated with the arc"
    cost::C
    "additional information associated with the arc"
    info::K = nothing
end

function Base.show(io::IO, arc::NetworkArc)
    return print(
        io,
        "NetworkArc(",
        "origin_id=$(arc.origin_id), ",
        "destination_id=$(arc.destination_id), ",
        "capacity=$(arc.capacity == typemax(Int) ? "∞" : string(arc.capacity)), ",
        "cost=$(arc.cost), ",
        "info=$(arc.info)",
        ")",
    )
end

# Conversion constructor to widen the cost type parameter
# This allows automatic conversion to union types
function NetworkArc{C,K}(arc::NetworkArc) where {C<:AbstractArcCostFunction,K}
    return NetworkArc{C,K}(;
        origin_id=arc.origin_id,
        destination_id=arc.destination_id,
        capacity=arc.capacity,
        cost=arc.cost,
        info=arc.info,
    )
end

function evaluate(arc_f::AbstractArcCostFunction)
    return 0.0
end

function evaluate(arc_f::LinearArcCost)
    return arc_f.cost_per_unit_size
end

function evaluate(arc_f::BinPackingArcCost)
    return arc_f.cost_per_bin
end

"""
    collect_arcs(cost_types, arcs; validate=true)

Collect an iterable of `NetworkArc`s into a type-stable vector with the specified cost types.
This is useful for creating heterogeneous arc collections with multiple cost function types
while maintaining type stability.

# Arguments
- `cost_types`: A tuple or Union of cost function types
  - Tuple syntax: `(LinearArcCost, BinPackingArcCost)`
  - Union syntax: `Union{LinearArcCost, BinPackingArcCost}`
- `arcs`: Iterable of NetworkArc objects with potentially different cost types
- `validate`: Whether to validate that all arc cost types are included (default: true)

# Examples
```julia
# Using tuple (recommended)
arcs = [NetworkArc(cost=LinearArcCost(1.0), ...), NetworkArc(cost=BinPackingArcCost(2.0, 10), ...)]
typed_arcs = collect_arcs((LinearArcCost, BinPackingArcCost), arcs)

# Using Union (also works)
const MyCostTypes = Union{LinearArcCost, BinPackingArcCost}
typed_arcs = collect_arcs(MyCostTypes, arcs)
```
"""
function collect_arcs(cost_types::Tuple, arcs::Vector{<:Arc}, time_step::Period; validate::Bool=true)
    # Convert tuple to Union
    CostUnion = Union{cost_types...}
    return collect_arcs(CostUnion, arcs, time_step; validate=validate)
end

function collect_arcs(
    union_types::Type{CostUnion}, arcs::Vector{<:Arc}, time_step::Period; validate::Bool=true
) where {CostUnion}
    if isempty(arcs)
        return NetworkArc{CostUnion,Nothing}[]
    end

    # Get the info type from the first arc
    first_arc = first(arcs)
    K = typeof(first_arc.info)

    # Optional validation: check that all cost types are covered
    if validate
        # Check each arc's cost type
        for arc in arcs
            cost_type = typeof(arc.cost)
            if !(cost_type <: CostUnion)
                error("""
                    Cost type $cost_type found in arcs but not declared.
                    Declared types: $(join(string.(union_types), ", "))

                    You need to add $cost_type to your cost types:
                    collect_arcs(($(join(string.(union_types), ", ")), $cost_type), arcs)
                    """)
            end
        end
    end

    # Convert all arcs to the union type
    return [
        NetworkArc{CostUnion,K}(;
            origin_id=arc.origin_id,
            destination_id=arc.destination_id,
            capacity=arc.capacity,
            travel_time=period_steps(arc.travel_time, time_step; roundup=ceil),
            cost=arc.cost,
            info=arc.info,
        ) for arc in arcs
    ]
end
