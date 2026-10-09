# [Type Transformations](@id type_transformations_guide)

When you call `Instance(nodes, arcs, commodities, time_step)`, the package transforms user-facing input types into optimized internal types.
This guide explains what happens at each stage.

## Overview

```
User input                         Internal types
─────────────────────────────────────────────────────────────
Commodity ──┐
            ├─ expand + group ──> LightCommodity ──> Order ──> Bundle
Commodity ──┘

Arc ────── convert ──> NetworkArc (or MultiModalArc)

Node ───── convert ──> NetworkNode

                         ┌─> NetworkGraph
NetworkNode + NetworkArc ┼─> TimeSpaceGraph
                         └─> TravelTimeGraph

All combined ──> Instance
```

## Commodity pipeline

### Commodity -> LightCommodity

[`Commodity`](@ref) is the user-facing input type.
It carries date information (`arrival_date` or `departure_date`), a `max_delivery_time`, and a `quantity` field for bulk creation.

During instance construction, each `Commodity` is expanded into `quantity` copies of [`LightCommodity`](@ref), which drops the date fields (those become the `time_step` index on the enclosing [`Order`](@ref)).

| Commodity field | LightCommodity field | Notes |
|-----------------|---------------------|-------|
| `origin_id` | `origin_id` | kept |
| `destination_id` | `destination_id` | kept |
| `size` | `size` | kept |
| `info` | `info` | kept |
| `date` | (moved to Order) | converted to a discrete `time_step` index |
| `max_delivery_time` | (moved to Order) | converted to `max_transit_steps` |
| `quantity` | (expanded) | one `LightCommodity` per unit |

### LightCommodity -> Order

Commodities that share the same origin, destination, delivery time step, and `group_by` key are grouped into a single [`Order`](@ref).

An `Order` holds:
- `commodities`: a `Vector{LightCommodity}`, sorted by descending size (for bin-packing)
- `time_step`: the discrete time index (arrival deadline or departure date)
- `max_transit_steps`: maximum transit time in time steps (minimum across grouped commodities)
- `total_size`: precomputed sum of commodity sizes
- `aggregate`: order-level summary of the commodities, `nothing` unless the problem overloads `order_aggregate`

### Order -> Bundle

Orders that share the same origin and destination (and `group_by` key) are grouped into a single [`Bundle`](@ref).

A `Bundle` holds:
- `orders`: a `Vector{Order}`
- `origin_id`, `destination_id`: shared routing endpoints
- `forbidden_nodes`, `forbidden_arcs`: aggregated constraints from all commodities in the bundle
- `total_size`: precomputed sum across all orders

Bundles are the routing unit: each bundle is assigned a single path in the [`TravelTimeGraph`](@ref).
All orders in a bundle follow the same spatial path but with order-specific timing.

## Node pipeline

### Node -> NetworkNode

[`Node`](@ref) is the user-facing input type, converted to a [`NetworkNode`](@ref) by [`collect_nodes`](@ref TransportationPlanningOptimization.collect_nodes) during instance construction.
Its fields are copied as is, except that `node_cost` is narrowed to a union type for type stability across heterogeneous cost functions.
Each `NetworkNode` links back to its `Node` through its `input_index`.
The role of a node (hub, plain origin or destination, or split into a hub and endpoint copies) is derived from the commodities and arcs, see the [Getting Started](../getting_started.md) page.
The `info` type parameter is taken from the first node, so all nodes must share one `info` type.

## Arc pipeline

### Arc -> NetworkArc

[`Arc`](@ref) is the user-facing input type with a `travel_time` as a `Period` (e.g., `Day(1)`, `Hour(6)`).

During instance construction, each `Arc` is converted to a [`NetworkArc`](@ref) where:
- `travel_time` (a `Period`) becomes `travel_time_steps` (an `Int`), computed via `period_steps`
- The `cost` function is narrowed to a union type for type stability across heterogeneous cost functions
- `input_index` is the position of the `Arc` in `instance.input.arcs`, also for every mode of a [`MultiModalArc`](@ref), read with [`input_arc_index`](@ref TransportationPlanningOptimization.input_arc_index)

When `allow_multimodal=true`, duplicate `(origin_id, destination_id)` arcs are auto-promoted to a [`MultiModalArc`](@ref) that bundles multiple transport modes on the same edge.
An `Arc` whose origin or destination is not among the nodes throws an `ArgumentError`.

## Graph layers

The network is expanded into three graph representations, each serving a different purpose:

### NetworkGraph

The spatial network: the converted nodes and arcs (plus the endpoint copies and virtual arcs of split nodes), without time expansion.
Built directly from the converted `Vector{NetworkNode}` and the converted `NetworkArc` tuples.

### TimeSpaceGraph

A time-expanded copy of the `NetworkGraph`.
Each spatial node is replicated for every time step in the horizon.
Arcs connect `(node, t)` to `(neighbor, t + travel_time_steps)`.

Used internally for tracking order-level timing constraints.

### TravelTimeGraph

A travel-time-expanded graph built per-bundle.
Each bundle gets dedicated origin and destination entry/exit nodes.
Arcs are grouped by travel time so that Dijkstra-based routing accounts for transit delays.

This is the graph the algorithms operate on: path costs are computed on its edges, and bundle paths are sequences of its node codes.

## The Instance

[`Instance`](@ref) bundles everything together:

```julia
Instance(;
    bundles,              # Vector{Bundle}
    network_graph,        # NetworkGraph
    time_horizon_length,  # Int
    time_step,            # Period
    time_step_to_date,    # Vector{DateTime} (start of each time step)
    time_space_graph,     # TimeSpaceGraph
    travel_time_graph,    # TravelTimeGraph
    index_cache,          # IndexCache (precomputed lookups for the hot path)
    input,                # InstanceInput (nodes, arcs and commodities as given by the user)
    commodity_to_order,   # Vector{Tuple{Int,Int}} (input commodity index to (bundle, order))
)
```

The `input` is kept exactly as given, and `commodity_to_order[k]` is the `(bundle_idx, order_idx)` of the `k`-th input commodity, or `(0, 0)` if it is not routed by the instance (origin equal to destination, or bundle dropped by an extraction).

Algorithms receive an `Instance` and produce a [`SolutionState`](@ref), which maps each bundle index to a path (sequence of node codes) in the `TravelTimeGraph`.
