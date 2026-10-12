# Getting Started

## The `Instance` Constructor

The entry point for creating an optimization problem is the `Instance` constructor:

```julia
Instance(
    nodes::Vector{<:Node},
    arcs::Vector{<:Arc},
    commodities::Vector{Commodity},
    time_step::Period;
    group_by=_default_group_by,
    wrap_time=false,
    check_bundle_feasibility=true
)
```

### Required Parameters

#### `nodes::Vector{Node}`

Physical locations in your network.
There is no node type to choose: the role of a node is derived when the instance is built, from the commodities and the arcs.

- A node that is not the origin or destination of any commodity is a hub, where routes can cross and freight can be consolidated.
- A pure endpoint stays a plain origin or destination.
  This is a commodity origin without incoming arcs, or a commodity destination without outgoing arcs.
- A crossable endpoint is a commodity origin or destination that routes can also cross.
  Internally it is split into a hub and endpoint copies linked by free virtual arcs.
  The split is invisible in the user-facing `Solution` and does not change any cost.
- `transit=false` forbids crossing the node, so it can only be the start or the end of a route.
  Its arcs that could only be used to cross it (an incoming arc when no commodity ends there, an outgoing arc when no commodity starts there) are ignored with a warning.
- Arcs from a node to itself are ignored with a warning.
- The `node_type` keyword is deprecated and ignored.

```julia
Node(;
    id::String,                                        # Unique identifier
    capacity::Int = typemax(Int),                      # Maximum throughput
    transit::Bool = true,                              # Whether routes may cross the node
    info = nothing,                                    # Optional metadata
    node_cost::AbstractNodeCostFunction = NoNodeCost() # Per-node cost function
)
```

#### `arcs::Vector{Arc}`

Transportation connections between nodes, representing roads, rail lines, shipping lanes, etc.

```julia
Arc(;
    origin_id::String,
    destination_id::String,
    cost::AbstractArcCostFunction,
    travel_time::Period,             # e.g., Day(2), Week(1)
    capacity::Int = typemax(Int),
    info = nothing
)
```

**Cost Functions:**
- `LinearArcCost(cost_per_unit)`: cost scales with volume (e.g., bulk shipping)
- `BinPackingArcCost(cost_per_bin, bin_capacity)`: fixed cost per vehicle/container

#### `commodities::Vector{Commodity}`

Items to transport through the network.

```julia
Commodity(;
    origin_id::String,
    destination_id::String,
    size::Float64,
    quantity::Int = 1,
    max_delivery_time::Period,
    # Either departure_date OR arrival_date (not both):
    departure_date::DateTime,    # When commodity is available at origin
    arrival_date::DateTime,      # Deadline at destination
    # Optional constraints:
    forbidden_node_ids::Vector{String} = String[],
    forbidden_arcs::Vector{Tuple{String,String}} = Tuple{String,String}[]
)
```

**Important:** Use `departure_date` when you know when the commodity is available at the origin or `arrival_date` when you know the arrival time at the destination. The `max_delivery_time` specifies the maximum transit duration.

#### `time_step::Period`

The discretization period for time-indexed decision variables. For example, `Day(1)` for daily steps or `Hour(6)` for 6-hour intervals.

### Optional Keyword Arguments

- **`group_by`**: Function to group commodities into orders (default groups by origin/destination)
- **`wrap_time`**: Set to `true` for cyclic/repeating time horizons (default: `false`)
- **`check_bundle_feasibility`**: Validate that each bundle has at least one feasible path (default: `true`)

## What the Constructor Does

When you create an `Instance`, the package:

1. **Discretizes time**: converts dates to integer time steps based on `time_step`
2. **Aggregates commodities** into a hierarchy:
   - `Commodity` → `LightCommodity` (expands by quantity)
   - `LightCommodity` → `Order` (groups by origin, destination, date, and additional grouping from `group_by`)
   - `Order` → `Bundle` (groups by origin, destination, and additional grouping from `group_by`)
3. **Builds graph structures**:
   - `NetworkGraph`: static network topology
   - `TimeSpaceGraph`: time-indexed network for routing
   - `TravelTimeGraph`: relative time representation for shortest paths
4. **Validates constraints** - Checks that each bundle has at least one feasible path if `check_bundle_feasibility` is `true`

## Basic Workflow

After creating an `Instance`, use it to:

1. **Solve** the optimization problem:
   ```julia
   solution = solve(instance)
   ```
   [`solve`](@ref) filters out trivial bundles, builds an initial solution and improves it with local search.
   It returns a [`Solution`](@ref) on your input arcs and commodities.
   Calling [`greedy_heuristic`](@ref) directly on a large instance is much slower.

2. **Validate** the solution:
   ```julia
   is_feasible(solution, instance; verbose=true)
   ```

3. **Evaluate** the objective:
   ```julia
   total_cost = cost(solution)
   ```

4. **Read** the solution, with dates, on your input arcs and commodities:
   ```julia
   solution.routes     # legs of each input commodity
   solution.arc_flows  # load and costs per input arc and departure date
   ```
   See [Reading a solution on the input network](@ref solution_guide).
   The internal [`SolutionState`](@ref) is described in [Working with SolutionState (advanced)](@ref solution_state_guide).

## Next Steps

- See the [Basic Example Tutorial](tutorials/basic_example.md) for a minimal hands-on example
- Learn about [Cost Functions](@ref cost_functions_guide) for choosing the right cost model
- Explore [Forbidden Constraints](@ref forbidden_constraints_guide) for routing restrictions
