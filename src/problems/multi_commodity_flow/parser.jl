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
With `fixed_costs=true` (default), each arc gets a `LinearArcCost(var_cost)` for the
routed volume plus a `BinPackingArcCost(fixed_cost, capacity)` that charges
`fixed_cost` once per used arc (the hard `capacity` keeps a single bin from ever
overflowing).
This is the fixed-charge multicommodity capacitated network design (MCND) instance.
With `fixed_costs=false`, each arc only gets `LinearArcCost(var_cost)` while keeping
the same `capacity`.
This is the unsplittable multicommodity flow (UMCF) instance.
Each commodity is an unsplittable demand of `size=demand` and `quantity=1`, sharing
one fixed `arrival_date` since the instances carry no time dimension.
"""
function parse_canad_instance(io::IO; fixed_costs::Bool=true)
    readline(io) # skip "MULTIGEN.DAT:" label line
    n_nodes, n_arcs, n_commodities = parse.(Int, split(readline(io)))

    nodes = [NetworkNode(; id=string(i), node_type=:other) for i in 1:n_nodes]

    arcs = map(1:n_arcs) do _
        tail, head, var_cost, capacity, fixed_cost = parse.(Int, split(readline(io)))
        cost = if fixed_costs
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
function parse_canad_instance(path::AbstractString; fixed_costs::Bool=true)
    return open(io -> parse_canad_instance(io; fixed_costs), path)
end

"""
$TYPEDSIGNATURES

Load instance `name` (without extension) from dataset `c`, downloading it on first
use.
`fixed_costs` selects the problem variant: the fixed-charge multicommodity capacitated
network design (MCND) instance by default, or the unsplittable multicommodity flow
(UMCF) instance with `fixed_costs=false`, see [`parse_canad_instance`](@ref).
"""
function load_instance(c::CanadC, name::AbstractString; fixed_costs::Bool=true)
    return parse_canad_instance(joinpath(dataset_dir(c), name * ".dow"); fixed_costs)
end
