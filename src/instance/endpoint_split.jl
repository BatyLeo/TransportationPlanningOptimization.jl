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
    "ids of the user nodes without a hub (`transit=false` origin and destination), their copies are in `origin_copy` and `destination_copy`"
    hubless::Set{String}
    "user node id of every copy"
    user_id::Dict{String,String}
end

function EndpointSplit()
    return EndpointSplit(
        Dict{String,String}(), Dict{String,String}(), Set{String}(), Dict{String,String}()
    )
end

"""
$TYPEDSIGNATURES

Translate the forbidden constraints of a bundle to the nodes of `split` that have no hub.
Forbidding such a node `v` forbids both its copies, the forbidden arc `(u, v)` becomes
`(u, v_d)` and `(v, w)` becomes `(v_o, w)`. Forbidding a node that has a hub changes nothing
(it blocks both virtual arcs). A forbidden arc on a skipped input arc between distinct nodes is kept,
it is harmless because it matches no internal arc. Loop arcs are dropped before this translation.
"""
function _translate_forbidden(split::EndpointSplit, forbidden_nodes, forbidden_arcs)
    isempty(split.hubless) && return forbidden_nodes, forbidden_arcs
    nodes = Set{String}()
    for id in forbidden_nodes
        if id in split.hubless
            push!(nodes, split.origin_copy[id], split.destination_copy[id])
        else
            push!(nodes, id)
        end
    end
    arcs = Set{Tuple{String,String}}()
    for (u, v) in forbidden_arcs
        push!(
            arcs,
            (
                u in split.hubless ? split.origin_copy[u] : u,
                v in split.hubless ? split.destination_copy[v] : v,
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

The internal arcs keep the position of their input arc as `input_index`. Every loop arc
(origin id equal to destination id) is ignored, as are the arcs skipped by the `transit=false`
rules. Ignored arcs have no internal arc and a separate warning reports each kind.
Duplicated node ids are rejected. The node cost and arc types are widened with the types of the
copies and virtual arcs only when some are created.
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
    # arc only if it is a destination and an outgoing arc only if it is an origin.
    # Every loop is ignored first, a path never uses an arc from a node to itself.
    loops = Tuple{Int,String,String}[]
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
        if o == d
            push!(loops, (i, o, d))
            continue
        end
        if (!by_id[o].transit && !(o in origins)) ||
            (!by_id[d].transit && !(d in destinations))
            push!(skipped, (i, o, d))
            continue
        end
        push!(kept, i)
        push!(has_out, o)
        push!(has_in, d)
    end

    taken = Set(keys(by_id))
    split = EndpointSplit()
    # one entry per internal node, `keep_cost` tells whether it keeps the node cost of its user node
    specs = @NamedTuple{k::Int, id::String, node_type::Symbol, keep_cost::Bool}[]
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
                push!(
                    specs,
                    (; k, id=d_id, node_type=:destination, keep_cost=true),
                    (; k, id=o_id, node_type=:origin, keep_cost=false),
                )
                split.origin_copy[id], split.destination_copy[id] = o_id, d_id
                push!(split.hubless, id)
                split.user_id[o_id], split.user_id[d_id] = id, id
            elseif is_origin
                push!(specs, (; k, id, node_type=:origin, keep_cost=true))
            elseif is_destination
                push!(specs, (; k, id, node_type=:destination, keep_cost=true))
            else
                push!(specs, (; k, id, node_type=:other, keep_cost=true))
                n_isolated += 1
            end
        elseif !is_origin && !is_destination
            push!(specs, (; k, id, node_type=:other, keep_cost=true))
        elseif is_origin && !is_destination && !(id in has_in)
            push!(specs, (; k, id, node_type=:origin, keep_cost=true))
        elseif is_destination && !is_origin && !(id in has_out)
            push!(specs, (; k, id, node_type=:destination, keep_cost=true))
        else
            push!(specs, (; k, id, node_type=:other, keep_cost=true))
            for (is_role, suffix, node_type, role_dict) in (
                (is_origin, "_o", :origin, split.origin_copy),
                (is_destination, "_d", :destination, split.destination_copy),
            )
                is_role || continue
                copy_id = _copy_id!(taken, id, suffix)
                push!(specs, (; k, id=copy_id, node_type, keep_cost=false))
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
        arc_tail = o in split.hubless ? split.origin_copy[o] : o
        arc_head = d in split.hubless ? split.destination_copy[d] : d
        push!(indexed_arcs, (arc_tail, arc_head, arc))
    end
    for (hub_id, copy_id, is_origin) in hub_copies
        virtual = NA2(; travel_time_steps=0, cost=VirtualArcCost())
        push!(
            indexed_arcs,
            is_origin ? (copy_id, hub_id, virtual) : (hub_id, copy_id, virtual),
        )
    end

    if !isempty(loops)
        i, o, d = first(loops)
        @warn "$(length(loops)) loop arc(s) ignored: an arc from a node to itself is never used (waiting at a node will be modeled by inventory), for example arc $i ($(repr(o)) -> $(repr(d)))"
    end
    messages = String[]
    if !isempty(skipped)
        examples = join(
            ("arc $i ($(repr(o)) -> $(repr(d)))" for (i, o, d) in first(skipped, 3)), ", "
        )
        push!(
            messages,
            "$(length(skipped)) input arc(s) skipped because they cross a node with `transit=false` (for example $examples)",
        )
    end
    if n_isolated > 0
        push!(
            messages,
            "$n_isolated node(s) with `transit=false` are neither the origin nor the destination of a commodity",
        )
    end
    isempty(messages) || @warn join(messages, ", ")
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

Internal nodes from the `specs` named tuples `(; k, id, node_type, keep_cost)`, where `k` is the
input node index and `keep_cost` tells whether the internal node keeps the node cost of the user
node. The node cost types are widened with [`NoNodeCost`](@ref) when some node does not keep it.
"""
function _collect_network_nodes(nodes::Vector{<:Node}, specs)
    cost_types = infer_node_cost_types(nodes)
    if any(s -> !s.keep_cost, specs)
        cost_types = Tuple(unique((cost_types..., NoNodeCost)))
    end
    base = collect_nodes(cost_types, nodes; validate=false)
    return [
        eltype(base)(
            id,
            node_type,
            base[k].capacity,
            base[k].info,
            keep_cost ? base[k].node_cost : NoNodeCost(),
            k,
        ) for (; k, id, node_type, keep_cost) in specs
    ]
end
