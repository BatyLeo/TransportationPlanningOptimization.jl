# # Basic Example Tutorial
#
# This tutorial demonstrates how to create and solve a simple transportation planning problem
# from scratch using TransportationPlanningOptimization.jl.

# ## Problem Setup
#
# We'll build a small network with:
# - 2 origin nodes (A1, A2)
# - 4 intermediate nodes (B1, B2, B3, B4)
# - 2 destination nodes (C1, C2)
#
# The network topology looks like this:
#
# ```
#        ┌──→ B1 ──→ B3 ───┐
#        │                 ↓
#    A1 ─┤              ┌─→ C1
#        │              │
#        └──→ B2 ──┬───→┘
#                  │
#        ┌──→ B4 ──┘    ┌─→ C2
#        │              │
#    A2 ─┴──────────────┘
# ```

# ## Load the Package

using TransportationPlanningOptimization
using Dates

# ## Define Network Nodes
#
# Create nodes with unique IDs and appropriate node types:

nodes = [
    NetworkNode(; id="A1", node_type=:origin),
    NetworkNode(; id="A2", node_type=:origin),
    NetworkNode(; id="B1", node_type=:other),
    NetworkNode(; id="B2", node_type=:other),
    NetworkNode(; id="B3", node_type=:other),
    NetworkNode(; id="B4", node_type=:other),
    NetworkNode(; id="C1", node_type=:destination),
    NetworkNode(; id="C2", node_type=:destination),
]

# ## Define Transportation Arcs
#
# Create arcs with linear costs (proportional to volume transported):

arcs = [
    Arc(; origin_id="A1", destination_id="B1", cost=LinearArcCost(5.0), travel_time=Day(1)),
    Arc(; origin_id="A1", destination_id="B2", cost=LinearArcCost(7.0), travel_time=Day(1)),
    Arc(; origin_id="A2", destination_id="B4", cost=LinearArcCost(6.0), travel_time=Day(1)),
    Arc(;
        origin_id="A2", destination_id="C2", cost=LinearArcCost(12.0), travel_time=Day(2)
    ),
    Arc(; origin_id="B1", destination_id="B3", cost=LinearArcCost(3.0), travel_time=Day(1)),
    Arc(; origin_id="B2", destination_id="C1", cost=LinearArcCost(4.0), travel_time=Day(1)),
    Arc(; origin_id="B2", destination_id="B4", cost=LinearArcCost(2.0), travel_time=Day(1)),
    Arc(; origin_id="B3", destination_id="C1", cost=LinearArcCost(5.0), travel_time=Day(1)),
    Arc(; origin_id="B4", destination_id="C1", cost=LinearArcCost(4.0), travel_time=Day(1)),
    Arc(; origin_id="B4", destination_id="C2", cost=LinearArcCost(6.0), travel_time=Day(1)),
]

# ## Define Commodities
#
# Create commodities to transport through the network:

base_date = DateTime(2025, 1, 1)

commodities = [
    Commodity(;  #src From A1 to C1, size 10, must arrive by day 3
        origin_id="A1",
        destination_id="C1",
        arrival_date=base_date + Day(3),
        max_delivery_time=Day(3),
        size=10.0,
    ),
    Commodity(;  #src From A1 to C1, size 5, must arrive by day 3 (same bundle as above)
        origin_id="A1",
        destination_id="C1",
        arrival_date=base_date + Day(3),
        max_delivery_time=Day(3),
        size=5.0,
    ),
    Commodity(;  #src From A2 to C2, size 8, must arrive by day 2
        origin_id="A2",
        destination_id="C2",
        arrival_date=base_date + Day(2),
        max_delivery_time=Day(2),
        size=8.0,
    ),
]

# ## Create the Instance
#
# Build the complete optimization instance with daily time steps:

instance = Instance(nodes, arcs, commodities, Day(1))

# ## Solve with Greedy Heuristic
#
# Apply the greedy insertion heuristic to find a solution:

solution = greedy_heuristic(instance)

# ## Validate and Evaluate the Solution
#
# Check if the solution is feasible:

is_feasible(solution, instance; verbose=true)

# Calculate the total cost:

cost(solution)

# The solution routes commodities through the network to minimize transportation costs
# while respecting delivery deadlines and network capacity constraints.
