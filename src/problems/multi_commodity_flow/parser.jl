"""
$TYPEDSIGNATURES

Parse a Canad C `.dow` instance from `io` and return it as an `Instance`.

The file format is:
```
MULTIGEN.DAT:
      20     228      39
       1       6      49    2846    2858       1      63
      18       6     216
```
The first data line gives `n_nodes n_arcs n_commodities`, each arc line gives
`tail head var_cost capacity fixed_cost` (2 trailing columns are ignored), and each
commodity line gives `origin destination demand`.
Nodes are `1:n_nodes`.
By default (`network_design=false`), each arc only gets a `LinearArcCost(var_cost)`
for the routed volume, keeping the hard `capacity`.
This is the Unsplittable Multicommodity Flow Problem (UMCF) instance.
With `network_design=true`, each arc additionally gets a
`BinPackingArcCost(fixed_cost, capacity)` that charges `fixed_cost` once per used arc
(the hard `capacity` keeps a single bin from ever overflowing).
This is the Multicommodity Flow Network Design Problem (MCFND) instance.
Each commodity is an unsplittable demand of `size=demand` and `quantity=1`, sharing
one fixed `arrival_date` since the instances carry no time dimension.
"""
function parse_canad_instance(io::IO; network_design::Bool=false)
    readline(io) # skip "MULTIGEN.DAT:" label line
    n_nodes, n_arcs, n_commodities = parse.(Int, split(readline(io)))

    nodes = [NetworkNode(; id=string(i), node_type=:other) for i in 1:n_nodes]

    arcs = map(1:n_arcs) do _
        tail, head, var_cost, capacity, fixed_cost = parse.(Int, split(readline(io)))
        cost = if network_design
            (LinearArcCost(var_cost), BinPackingArcCost(fixed_cost, capacity))
        else
            LinearArcCost(var_cost)
        end
        return Arc(;
            origin_id=string(tail),
            destination_id=string(head),
            travel_time=Day(0),
            capacity=capacity,
            cost=cost,
        )
    end

    commodities = map(1:n_commodities) do _
        origin, destination, demand = parse.(Int, split(readline(io)))
        return Commodity(;
            origin_id=string(origin),
            destination_id=string(destination),
            size=Float64(demand),
            quantity=1,
            arrival_date=DateTime(2000, 1, 1), # no time dimension, any date works
            max_delivery_time=Day(0),
        )
    end

    return Instance(nodes, arcs, commodities, Day(1))
end

"""
$TYPEDSIGNATURES

Parse a Canad C `.dow` instance from the file at `path`.
"""
function parse_canad_instance(path::AbstractString; network_design::Bool=false)
    return open(io -> parse_canad_instance(io; network_design), path)
end

"""
$TYPEDSIGNATURES

Load instance `name` (without extension) from dataset `c`, downloading it on first
use.
`network_design` selects the problem variant: the Unsplittable Multicommodity Flow
Problem (UMCF) instance by default, or the Multicommodity Flow Network Design Problem
(MCFND) instance with `network_design=true`, see [`parse_canad_instance`](@ref).
"""
function load_instance(c::CanadC, name::AbstractString; network_design::Bool=false)
    return parse_canad_instance(joinpath(dataset_dir(c), name * ".dow"); network_design)
end
