"""
$TYPEDSIGNATURES

Parse a Canad C `.dow` instance from `io` and return it as an `_MCFData`.

The file format is:
```
MULTIGEN.DAT:
      20     228      39
       1       6      49    2846    2858       1      63
      18       6     216
```
Lines give, in order, `n_nodes n_arcs n_commodities`, then one `tail head var_cost
capacity fixed_cost` line per arc (trailing columns, if any, are ignored), then one
`origin destination demand` line per commodity.
"""
function _parse_canad_data(io::IO; network_design::Bool=false)
    readline(io) # skip "MULTIGEN.DAT:" label line
    n_nodes, n_arcs, n_commodities = parse.(Int, split(readline(io)))

    tails = Vector{Int}(undef, n_arcs)
    heads = Vector{Int}(undef, n_arcs)
    var_costs = Vector{Int}(undef, n_arcs)
    capacities = Vector{Int}(undef, n_arcs)
    fixed_costs = Vector{Int}(undef, n_arcs)
    for a in 1:n_arcs
        tail, head, var_cost, capacity, fixed_cost = parse.(Int, split(readline(io)))
        tails[a] = tail
        heads[a] = head
        var_costs[a] = var_cost
        capacities[a] = capacity
        fixed_costs[a] = fixed_cost
    end

    origins = Vector{Int}(undef, n_commodities)
    destinations = Vector{Int}(undef, n_commodities)
    demands = Vector{Int}(undef, n_commodities)
    for k in 1:n_commodities
        origin, destination, demand = parse.(Int, split(readline(io)))
        origins[k] = origin
        destinations[k] = destination
        demands[k] = demand
    end

    return _MCFData(;
        n_nodes,
        tails,
        heads,
        var_costs,
        capacities,
        fixed_costs,
        origins,
        destinations,
        demands,
        network_design,
    )
end

"""
$TYPEDSIGNATURES

Parse a Canad C `.dow` instance from the file at `path`.
"""
function _parse_canad_data(path::AbstractString; network_design::Bool=false)
    return open(io -> _parse_canad_data(io; network_design), path)
end

"""
$TYPEDSIGNATURES

Build the package `Instance` for `data`, see [`load_instance`](@ref) for the resulting
problem variants.
"""
function _to_instance(data::_MCFData)
    nodes = [Node(; id=string(i)) for i in 1:(data.n_nodes)]

    arcs = map(eachindex(data.tails)) do a
        cost = if data.network_design
            (
                LinearArcCost(data.var_costs[a]),
                BinPackingArcCost(data.fixed_costs[a], data.capacities[a]),
            )
        else
            LinearArcCost(data.var_costs[a])
        end
        return Arc(;
            origin_id=string(data.tails[a]),
            destination_id=string(data.heads[a]),
            travel_time=Day(0),
            capacity=data.capacities[a],
            cost=cost,
        )
    end

    commodities = map(eachindex(data.origins)) do k
        return Commodity(;
            origin_id=string(data.origins[k]),
            destination_id=string(data.destinations[k]),
            size=Float64(data.demands[k]),
            quantity=1,
            arrival_date=DateTime(2000, 1, 1), # no time dimension, any date works
            max_delivery_time=Day(0),
            info=k, # key for `group_by` below
        )
    end

    # One bundle per commodity: unsplittable flow routes each commodity on its own path,
    # so two commodities with the same endpoints can take different paths.
    return Instance(nodes, arcs, commodities, Day(1); group_by=c -> c.info)
end

"""
$TYPEDSIGNATURES

Parse a Canad C `.dow` instance from `io` and return it as an `Instance`, see
[`load_instance`](@ref) for the resulting problem variants.
"""
function parse_canad_instance(io::IO; network_design::Bool=false)
    return _to_instance(_parse_canad_data(io; network_design))
end

"""
$TYPEDSIGNATURES

Parse a Canad C `.dow` instance from the file at `path` and return it as an `Instance`.
"""
function parse_canad_instance(path::AbstractString; network_design::Bool=false)
    return _to_instance(_parse_canad_data(path; network_design))
end

"""
$TYPEDSIGNATURES

Load `_MCFData` for instance `name` (without extension) from dataset `c`,
downloading it on first use.
`network_design` selects the problem variant, see [`load_instance`](@ref).
"""
function _load_data(c::CanadC, name::AbstractString; network_design::Bool=false)
    return _parse_canad_data(joinpath(dataset_dir(c), name * ".dow"); network_design)
end

"""
$TYPEDSIGNATURES

Load instance `name` (without extension) from dataset `c` as an `Instance`, downloading
it on first use.

By default (`network_design=false`), this is the Unsplittable Multicommodity Flow
Problem (UMCF): each arc has a [`LinearArcCost`](@ref) and a hard `capacity`.
With `network_design=true`, this is the Multicommodity Flow Network Design Problem
(MCFND): each arc also gets a [`BinPackingArcCost`](@ref) charging its fixed cost once
per used arc.
Each commodity forms its own bundle, so commodities with the same endpoints can take
different paths.
"""
function load_instance(c::CanadC, name::AbstractString; network_design::Bool=false)
    return _to_instance(_load_data(c, name; network_design))
end
