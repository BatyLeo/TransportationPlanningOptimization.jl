# Shared, memoized test fixtures. Parsing and Instance construction for the
# benchmark instances is expensive, so build each one once and reuse it.
# Instance is immutable, but solvers also write per-bundle Dijkstra scratch
# into the shared `instance.travel_time_graph.cost_matrix` (and
# `cost_scaling`, for slope scaling). Sharing instances is safe only because
# every reader either writes that scratch before reading it, or builds its
# own private instance. Tests that ASSERT on `cost_scaling` must call
# `reset!()` first (see TestFixtures.reset!).

module TestFixtures

using TransportationPlanningOptimization
using Dates
using MetaGraphsNext
using Random
using Test
using TransportationPlanningOptimization.Problems.Inbound: parse_inbound_instance

const DATADIR = joinpath(@__DIR__, "public")

# name => memoized parsed (; nodes, arcs, commodities)
const _PARSED = Dict{String,Any}()
# (name, wrap_time) => memoized built Instance
const _INSTANCE = Dict{Tuple{String,Bool},Any}()
# (name, wrap_time) => memoized greedy SolutionState (never handed out directly)
const _GREEDY = Dict{Tuple{String,Bool},Any}()

function _parsed(name::String)
    return get!(_PARSED, name) do
        return parse_inbound_instance(
            joinpath(DATADIR, "$(name)_nodes.csv"),
            joinpath(DATADIR, "$(name)_legs.csv"),
            joinpath(DATADIR, "$(name)_commodities.csv"),
        )
    end
end

function _instance(name::String, wrap_time::Bool)
    return get!(_INSTANCE, (name, wrap_time)) do
        (; nodes, arcs, commodities) = _parsed(name)
        return Instance(nodes, arcs, commodities, Week(1); wrap_time=wrap_time)
    end
end

function _greedy(name::String, wrap_time::Bool)
    sol = get!(_GREEDY, (name, wrap_time)) do
        return greedy_heuristic(_instance(name, wrap_time); show_progress=false)
    end
    return deepcopy(sol)
end

# Mock perturbation that removes and reinserts a random bundle along its cheapest path.
struct ReinsertPerturbation <: AbstractPerturbation end

function TransportationPlanningOptimization.perturbate!(
    sol::SolutionState,
    instance::Instance,
    ::ReinsertPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    isempty(instance.bundles) && return (0.0, 0)
    idx = rand(rng, 1:length(instance.bundles))
    isempty(sol.bundle_paths[idx]) && return (0.0, 0)

    before = cost(sol)
    TransportationPlanningOptimization.remove_bundle_path!(sol, instance, idx)

    ttg = instance.travel_time_graph
    TransportationPlanningOptimization.update_bundle_cost_matrix!(sol, instance, idx)
    origin = ttg.origin_codes[idx]
    destination = ttg.destination_codes[idx]
    path = TransportationPlanningOptimization.bundle_shortest_path(
        instance, origin, destination
    )
    if !isempty(path)
        TransportationPlanningOptimization.add_bundle_path!(sol, instance, idx, path)
    end
    return (before - cost(sol), 1)
end

tiny_parsed() = _parsed("tiny")
small_parsed() = _parsed("small")

tiny_instance(; wrap_time::Bool=true) = _instance("tiny", wrap_time)
small_instance(; wrap_time::Bool=true) = _instance("small", wrap_time)

tiny_greedy(; wrap_time::Bool=true) = _greedy("tiny", wrap_time)
small_greedy(; wrap_time::Bool=true) = _greedy("small", wrap_time)

# Four-node instance where F (A->B, size 3) is filtered out as a direct path and
# K (A->D2, size 4) is kept: K's cheap route through B shares the capacity-5
# arc A->B with F, so it must route around it through C.
# With `b_type=:destination`, B belongs to F alone and the filtering drops it with its arcs.
function shared_arc_instance(; b_type::Symbol=:other)
    nodes = [
        Node(; id="A", node_type=:origin),
        Node(; id="B", node_type=b_type),
        Node(; id="C", node_type=:other),
        Node(; id="D2", node_type=:destination),
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=LinearArcCost(1.0),
            travel_time=Day(1),
            capacity=5,
        ),
        Arc(;
            origin_id="B", destination_id="D2", cost=LinearArcCost(1.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="A", destination_id="C", cost=LinearArcCost(2.0), travel_time=Day(1)
        ),
        Arc(;
            origin_id="C", destination_id="D2", cost=LinearArcCost(2.0), travel_time=Day(1)
        ),
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(1),
            size=3.0,
        ),
        Commodity(;
            origin_id="A",
            destination_id="D2",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=4.0,
        ),
    ]
    return Instance(nodes, arcs, commodities, Day(1))
end

# Origin id, destination id and transit steps of an input arc.
function _input_arc_leg(a::Arc, time_step)
    return (
        a.origin_id,
        a.destination_id,
        TransportationPlanningOptimization.period_steps(
            a.travel_time, time_step; roundup=floor
        ),
    )
end
_input_arc_leg(a::Tuple, time_step) = (a[1], a[2], a[3].travel_time_steps)

# Check the provenance links of every node and arc mode of the three graphs.
# `complete=false` skips the exhaustive index checks (for filtered sub-instances).
function check_input_links(instance; complete::Bool=true)
    input = instance.input
    ng = instance.network_graph.graph
    for label in MetaGraphsNext.labels(ng)
        @test ng[label].input_index > 0
        @test input.nodes[ng[label].input_index].id == label
    end
    seen = Int[]
    for (name, graph) in (
        ("network", ng),
        ("tsg", instance.time_space_graph.graph),
        ("ttg", instance.travel_time_graph.graph),
    )
        for (u, v) in MetaGraphsNext.edge_labels(graph)
            arc = graph[u, v]
            if arc === TransportationPlanningOptimization.SHORTCUT_ARC
                @test arc.input_index == 0
                continue
            end
            modes = arc isa MultiModalArc ? arc.modes : [arc]
            for (slot, mode) in enumerate(modes)
                k = TransportationPlanningOptimization.input_arc_index(arc, slot)
                @test k > 0
                k > 0 || continue
                o, d, steps = _input_arc_leg(input.arcs[k], instance.time_step)
                u1 = u isa Tuple ? u[1] : u
                v1 = v isa Tuple ? v[1] : v
                @test (o, d) == (u1, v1)
                @test steps == mode.travel_time_steps
                name == "network" && push!(seen, k)
            end
        end
    end
    if complete
        @test sort([ng[l].input_index for l in MetaGraphsNext.labels(ng)]) == 1:length(input.nodes)
        @test sort(seen) == 1:length(input.arcs)
    end
    return nothing
end

# Leg A -> B with `modes` given as (cost per unit or arc cost, travel days, capacity) tuples.
# `departure_days` are spread so that a wrapped horizon exceeds every transit time.
# The commodity dates are departure dates, or arrival dates with `arrival=true`.
# `node_cost` is the node cost of B.
function _leg_instance(
    modes,
    max_delivery_days;
    quantity=2,
    departure_days=(1,),
    wrap_time=false,
    node_cost=NoNodeCost(),
    arrival::Bool=false,
)
    nodes = [
        Node(; id="A", node_type=:origin), Node(; id="B", node_type=:destination, node_cost)
    ]
    arcs = [
        Arc(;
            origin_id="A",
            destination_id="B",
            cost=c isa Real ? LinearArcCost(c) : c,
            travel_time=Day(d),
            capacity=cap,
        ) for (c, d, cap) in modes
    ]
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="B",
            quantity=quantity,
            (arrival ? :arrival_date : :departure_date) => DateTime(2024, 1, d),
            max_delivery_time=Day(max_delivery_days),
            size=1.0,
        ) for d in departure_days
    ]
    return Instance(nodes, arcs, commodities, Day(1); allow_multimodal=true, wrap_time)
end

const _TRUCK_TRAIN_MODES = [(10.0, 1, 10), (5.0, 2, 10)]

# Check the arc flows of `ns` against `sol`: costs, volume, bins and unique rows.
function check_flows(ns, sol)
    flows = ns.arc_flows
    @test sum(f -> f.arc_cost + f.node_cost, flows; init=0.0) ≈ cost(sol)
    @test sum(f -> f.arc_cost, flows; init=0.0) ≈ total_arc_cost(sol)
    @test sum(f -> f.node_cost, flows; init=0.0) ≈ total_node_cost(sol)
    @test sum(f -> f.volume, flows; init=0.0) ≈
        sum(total_size_of(a) for a in values(sol.assignments); init=0.0)
    @test allunique((f.arc, f.departure) for f in flows)
    @test issorted(flows; by=f -> (f.arc, f.departure))
    slots = [
        slot for a in values(sol.assignments) for slot in
        (a isa TransportationPlanningOptimization.MultiAssignment ? a.per_mode : [a]) if
        !isempty(slot.commodities)
    ]
    if !any(slot -> slot.bins_dirty, slots)
        @test sum(f -> f.n_bins, flows; init=0) ==
            sum(slot -> length(slot.bins), slots; init=0)
    end
    return nothing
end

# Cyclic time step of a date, to compare route dates with `arc_flows` dates.
function _cyclic_step(date, instance)
    steps = TransportationPlanningOptimization.period_steps(
        date - instance.time_step_to_date[1], instance.time_step; roundup=floor
    )
    return instance.time_space_graph.wrap_time ? mod(steps, instance.time_horizon_length) :
           steps
end

# Check the routes of `ns` commodity by commodity and their loads against the arc flows
# (an upper bound with `reservations`). Failing commodities are collected per predicate.
function check_routes(ns, sol, instance; reservations::Bool=false)
    TPO = TransportationPlanningOptimization
    Δ = instance.time_step
    start = instance.time_step_to_date[1]
    input = instance.input
    @test length(ns.routes) == length(input.commodities)
    names = (:empty, :quantity, :chain, :transit, :back_to_back, :ends)
    bad = Dict(name => Int[] for name in names)
    load = Dict{Tuple{Int,Int},Float64}()
    for (k, c) in enumerate(input.commodities)
        legs = ns.routes[k]
        b, o = instance.commodity_to_order[k]
        if b == 0
            isempty(legs) || push!(bad[:empty], k)
            continue
        end
        isempty(legs) == (length(sol.bundle_paths[b]) < 2) || push!(bad[:empty], k)
        isempty(legs) && continue
        order = instance.bundles[b].orders[o]
        order_date = start + (order.time_step - 1) * Δ
        # Group the legs by path position: a position is complete once it carries `quantity` copies.
        groups = Vector{Vector{eltype(legs)}}()
        position_quantity = c.quantity
        for leg in legs
            if position_quantity == c.quantity
                push!(groups, eltype(legs)[])
                position_quantity = 0
            end
            push!(groups[end], leg)
            position_quantity += leg.quantity
        end
        position_quantity == c.quantity || push!(bad[:quantity], k)
        previous_destination = c.origin_id
        previous_arrival = nothing
        for group in groups
            o_id, d_id, steps = _input_arc_leg(input.arcs[group[1].arc], Δ)
            all(l -> _input_arc_leg(input.arcs[l.arc], Δ) == (o_id, d_id, steps), group) &&
            o_id == previous_destination || push!(bad[:chain], k)
            all(
                l ->
                    l.departure == group[1].departure &&
                    l.arrival == group[1].arrival &&
                    l.arrival - l.departure == steps * Δ,
                group,
            ) || push!(bad[:transit], k)
            isnothing(previous_arrival) ||
                group[1].departure == previous_arrival ||
                push!(bad[:back_to_back], k)
            for leg in group
                key = (leg.arc, _cyclic_step(leg.departure, instance))
                load[key] = get(load, key, 0.0) + c.size * leg.quantity
            end
            previous_destination = d_id
            previous_arrival = group[1].arrival
        end
        previous_destination == c.destination_id || push!(bad[:ends], k)
        if TPO.is_date_arrival(instance.travel_time_graph)
            (previous_arrival == order_date && previous_arrival <= c.date) ||
                push!(bad[:ends], k)
        else
            (groups[1][1].departure == order_date && order_date <= c.date) ||
                push!(bad[:ends], k)
        end
    end
    for name in names
        @test (name => bad[name]) == (name => Int[])
    end
    flows = Dict(
        (f.arc, _cyclic_step(f.departure, instance)) => f.volume for f in ns.arc_flows
    )
    if reservations
        @test (:load => [k for (k, v) in load if get(flows, k, -Inf) < v - 1e-9]) == (:load => [])
    else
        @test keys(flows) == keys(load)
        @test (:load => [k for (k, v) in load if !(flows[k] ≈ v)]) == (:load => [])
    end
    return nothing
end

# Extend every path with the chain of shortcut nodes that the travel-time graph allows.
function add_shortcuts!(sol, instance)
    g = instance.travel_time_graph.graph
    arrival = TransportationPlanningOptimization.is_date_arrival(instance.travel_time_graph)
    added = 0
    for path in sol.bundle_paths
        id, τ = MetaGraphsNext.label_for(g, arrival ? first(path) : last(path))
        while haskey(g, (id, τ + 1))
            τ += 1
            code = MetaGraphsNext.code_for(g, (id, τ))
            arrival ? pushfirst!(path, code) : push!(path, code)
            added += 1
        end
    end
    return added
end

# Whether two lists of arc flows agree on dates, bins and (up to rounding) volumes and costs.
function flows_match(a, b)
    return length(a) == length(b) && all(
        x.arc == y.arc &&
        x.departure == y.departure &&
        x.arrival == y.arrival &&
        x.n_bins == y.n_bins &&
        x.volume ≈ y.volume &&
        x.arc_cost ≈ y.arc_cost &&
        x.node_cost ≈ y.node_cost for (x, y) in zip(a, b)
    )
end

# Project `state` onto the input and rebuild it, then check the rebuilt state.
# `same_cost` is true when the repack is known to reproduce the packing of `state` (linear costs,
# or instances where first-fit decreasing coincides with it, like tiny), then bins and costs must match too.
function check_round_trip(state, instance; same_cost::Bool)
    TPO = TransportationPlanningOptimization
    solution = Solution(state, instance)
    rebuilt = SolutionState(solution, instance)
    @test is_feasible(rebuilt, instance; verbose=true)
    stripped = map(state.bundle_paths) do path
        path = copy(path)
        TPO._remove_shortcuts_from_path!(path, instance.travel_time_graph)
        return path
    end
    @test rebuilt.bundle_paths == stripped
    again = Solution(rebuilt, instance)
    @test again.routes == solution.routes
    if same_cost
        @test cost(rebuilt) ≈ cost(state)
        @test flows_match(again.arc_flows, solution.arc_flows)
    end
    return rebuilt
end

# Clear any cost_scaling mutations left on the shared instances.
function reset!()
    for inst in values(_INSTANCE)
        empty!(inst.travel_time_graph.cost_scaling)
    end
    return nothing
end

end # module
