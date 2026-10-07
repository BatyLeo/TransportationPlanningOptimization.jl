"""
$TYPEDEF

How the user nodes were turned into internal nodes when an [`Instance`](@ref) was built.
A user node `v` that is a commodity endpoint is rooted on an origin copy `v_o` and/or a
destination copy `v_d`, see [`_derive_network`](@ref).

# Fields
$TYPEDFIELDS
"""
struct EndpointSplit
    "id of the origin copy of the user nodes that have one, bundles starting there are rooted on it"
    origin_copy::Dict{String,String}
    "id of the destination copy of the user nodes that have one, bundles ending there are rooted on it"
    destination_copy::Dict{String,String}
    "user nodes without a hub (`transit=false` origin and destination), mapped to their `(origin copy, destination copy)` ids"
    hubless::Dict{String,Tuple{String,String}}
    "user node id of every copy"
    user_id::Dict{String,String}
    "`(origin, destination)` user ids of the input arcs that were skipped"
    skipped_arcs::Set{Tuple{String,String}}
end

function EndpointSplit()
    return EndpointSplit(
        Dict{String,String}(),
        Dict{String,String}(),
        Dict{String,Tuple{String,String}}(),
        Dict{String,String}(),
        Set{Tuple{String,String}}(),
    )
end

"""
$TYPEDSIGNATURES

Translate the forbidden constraints of a bundle to the nodes of `split` that have no hub.
Forbidding such a node `v` forbids both its copies, the forbidden arc `(u, v)` becomes
`(u, v_d)` and `(v, w)` becomes `(v_o, w)`. Forbidding a node that has a hub changes nothing
(it blocks both virtual arcs). The forbidden arcs that match a skipped input arc are dropped.
"""
function _translate_forbidden(split::EndpointSplit, forbidden_nodes, forbidden_arcs)
    isempty(split.hubless) &&
        isempty(split.skipped_arcs) &&
        return forbidden_nodes, forbidden_arcs
    nodes = Set{String}()
    for id in forbidden_nodes
        copies = get(split.hubless, id, nothing)
        isnothing(copies) ? push!(nodes, id) : union!(nodes, copies)
    end
    arcs = Set{Tuple{String,String}}()
    for (u, v) in forbidden_arcs
        (u, v) in split.skipped_arcs && continue
        u_copies = get(split.hubless, u, nothing)
        v_copies = get(split.hubless, v, nothing)
        push!(
            arcs,
            (
                isnothing(u_copies) ? u : first(u_copies),
                isnothing(v_copies) ? v : last(v_copies),
            ),
        )
    end
    return nodes, arcs
end

"""
$TYPEDSIGNATURES

Id of a copy of node `id`: `id` followed by `suffix`, extended with `suffix` until it clashes
with no id of `taken`. The returned id is added to `taken`.
"""
function _copy_id!(taken::Set{String}, id::String, suffix::String)
    copy_id = id * suffix
    while copy_id in taken
        copy_id *= suffix
    end
    push!(taken, copy_id)
    return copy_id
end

"""
$TYPEDSIGNATURES

Derive the internal nodes and arcs of an instance from the user nodes, the arcs and the
moving commodities (the keys of `order_dict`). Returns `(network_nodes, indexed_arcs, split)`
where `split` is an [`EndpointSplit`](@ref).

Let `v` be a user node, `O` whether some commodity starts at `v` and `D` whether some
commodity ends at `v`:
- `transit=false`: an incoming arc is created only if `D` and an outgoing arc only if `O`.
  If both hold, `v` becomes two disconnected nodes: `v_d` (`:destination`, incoming arcs and
  the node cost of `v`) and `v_o` (`:origin`, outgoing arcs). Otherwise it stays a single node
  with id `v` typed `:origin`, `:destination` or `:other` (isolated).
- `transit=true` and neither `O` nor `D`: a hub (`:other`).
- `transit=true`, `O` and no incoming arc: a plain `:origin`. Symmetrically a plain
  `:destination` for `D` and no outgoing arc.
- any other `transit=true` endpoint: a hub `v` (node cost and all arcs) plus `v_o` if `O` and
  `v_d` if `D`, linked by virtual arcs `v_o -> v` and `v -> v_d` (see [`VirtualArcCost`](@ref)).
  The copies have no node cost, so the split does not change any cost.

The internal arcs keep the position of their input arc as `input_index`. The skipped arcs
(including the loops on `transit=false` nodes) have no internal arc and a warning reports
them. The arcs that make a `transit=true` node crossable are the kept ones that are not
loops. Duplicated node ids are rejected. The node cost and arc types are widened with
the types of the copies and virtual arcs only when some are created.
"""
function _derive_network(
    nodes::Vector{<:Node}, arcs::Vector{Tuple{String,String,NA}}, order_dict
) where {NA<:NetworkArc}
    by_id = Dict{String,Node}()
    for (k, node) in enumerate(nodes)
        if haskey(by_id, node.id)
            first_k = findfirst(n -> n.id == node.id, nodes)
            throw(
                ArgumentError(
                    "duplicate node id $(repr(node.id)) at input positions $first_k and $k, each node needs a unique id",
                ),
            )
        end
        by_id[node.id] = node
    end
    origins = Set(key[2] for key in keys(order_dict))
    destinations = Set(key[3] for key in keys(order_dict))

    # Skipped arcs depend only on the commodities: a `transit=false` node keeps an incoming
    # arc only if it is a destination, an outgoing arc only if it is an origin, and no loop.
    # A loop on a `transit=true` node is kept but does not make the node crossable.
    skipped = Tuple{Int,String,String}[]
    kept = Int[]
    has_in = Set{String}()
    has_out = Set{String}()
    for (i, (o, d, _)) in enumerate(arcs)
        for id in (o, d)
            haskey(by_id, id) || throw(
                ArgumentError(
                    "arc $i ($(repr(o)), $(repr(d))) has an unknown endpoint: $(repr(id)) is not in nodes (add a Node with this id or remove the arc)",
                ),
            )
        end
        if (!by_id[o].transit && (o == d || !(o in origins))) ||
            (!by_id[d].transit && !(d in destinations))
            push!(skipped, (i, o, d))
            continue
        end
        push!(kept, i)
        if o != d
            push!(has_out, o)
            push!(has_in, d)
        end
    end

    taken = Set(keys(by_id))
    split = EndpointSplit()
    union!(split.skipped_arcs, (o, d) for (_, o, d) in skipped)
    # (input node index, id, node_type, node cost is dropped)
    specs = Tuple{Int,String,Symbol,Bool}[]
    hub_copies = Tuple{String,String,Bool}[]  # (hub id, copy id, copy is an origin)
    n_isolated = 0

    for (k, node) in enumerate(nodes)
        id = node.id
        is_origin = id in origins
        is_destination = id in destinations
        if !node.transit
            if is_origin && is_destination
                d_id = _copy_id!(taken, id, "_d")
                o_id = _copy_id!(taken, id, "_o")
                push!(specs, (k, d_id, :destination, false), (k, o_id, :origin, true))
                split.origin_copy[id], split.destination_copy[id] = o_id, d_id
                split.hubless[id] = (o_id, d_id)
                split.user_id[o_id], split.user_id[d_id] = id, id
            elseif is_origin
                push!(specs, (k, id, :origin, false))
            elseif is_destination
                push!(specs, (k, id, :destination, false))
            else
                push!(specs, (k, id, :other, false))
                n_isolated += 1
            end
        elseif !is_origin && !is_destination
            push!(specs, (k, id, :other, false))
        elseif is_origin && !is_destination && !(id in has_in)
            push!(specs, (k, id, :origin, false))
        elseif is_destination && !is_origin && !(id in has_out)
            push!(specs, (k, id, :destination, false))
        else
            push!(specs, (k, id, :other, false))
            for (is_role, suffix, node_type, role_dict) in (
                (is_origin, "_o", :origin, split.origin_copy),
                (is_destination, "_d", :destination, split.destination_copy),
            )
                is_role || continue
                copy_id = _copy_id!(taken, id, suffix)
                push!(specs, (k, copy_id, node_type, true))
                push!(hub_copies, (id, copy_id, node_type == :origin))
                role_dict[id] = copy_id
                split.user_id[copy_id] = id
            end
        end
    end

    network_nodes = _collect_network_nodes(nodes, specs)
    NA2 = isempty(hub_copies) ? NA : _with_virtual_arcs(NA)
    indexed_arcs = Tuple{String,String,NA2}[]
    for i in kept
        o, d, a = arcs[i]
        arc = NA2(;
            travel_time_steps=a.travel_time_steps,
            capacity=a.capacity,
            cost=a.cost,
            info=a.info,
            input_index=i,
        )
        arc_tail = haskey(split.hubless, o) ? first(split.hubless[o]) : o
        arc_head = haskey(split.hubless, d) ? last(split.hubless[d]) : d
        push!(indexed_arcs, (arc_tail, arc_head, arc))
    end
    for (hub_id, copy_id, is_origin) in hub_copies
        virtual = NA2(; travel_time_steps=0, cost=VirtualArcCost())
        push!(
            indexed_arcs,
            is_origin ? (copy_id, hub_id, virtual) : (hub_id, copy_id, virtual),
        )
    end

    if !isempty(skipped)
        examples = join(
            ("arc $i ($(repr(o)) -> $(repr(d)))" for (i, o, d) in first(skipped, 3)), ", "
        )
        @warn "$(length(skipped)) input arc(s) skipped because they cross or loop on a node with `transit=false` (for example $examples), $n_isolated such node(s) are neither the origin nor the destination of a commodity"
    end
    return network_nodes, indexed_arcs, split
end

"""
$TYPEDSIGNATURES

Arc type of `NA` widened with the virtual arc cost and a `Nothing` info.
"""
function _with_virtual_arcs(::Type{NA}) where {NA<:NetworkArc}
    isconcretetype(NA) || throw(
        ArgumentError(
            "cannot split endpoints with arcs of the abstract type $NA, use a concrete NetworkArc{C,K} (see `collect_arcs`)",
        ),
    )
    C, K = NA.parameters
    return NetworkArc{Union{C,VirtualArcCost},Union{K,Nothing}}
end

"""
$TYPEDSIGNATURES

Internal nodes from the `specs` `(input node index, id, node_type, node cost is dropped)`.
The node cost types are widened with [`NoNodeCost`](@ref) when a copy drops its node cost.
"""
function _collect_network_nodes(nodes::Vector{<:Node}, specs)
    cost_types = infer_node_cost_types(nodes)
    if any(last, specs)
        cost_types = Tuple(unique((cost_types..., NoNodeCost)))
    end
    base = collect_nodes(cost_types, nodes; validate=false)
    return [
        eltype(base)(
            id,
            node_type,
            base[k].capacity,
            base[k].info,
            dropped ? NoNodeCost() : base[k].node_cost,
            k,
        ) for (k, id, node_type, dropped) in specs
    ]
end
