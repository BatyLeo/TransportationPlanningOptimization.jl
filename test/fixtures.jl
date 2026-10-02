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
using Random
using TransportationPlanningOptimization.Problems.Inbound: parse_inbound_instance

const DATADIR = joinpath(@__DIR__, "public")

# name => memoized parsed (; nodes, arcs, commodities)
const _PARSED = Dict{String,Any}()
# (name, wrap_time) => memoized built Instance
const _INSTANCE = Dict{Tuple{String,Bool},Any}()
# (name, wrap_time) => memoized greedy Solution (never handed out directly)
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
    sol::Solution,
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
function shared_arc_instance()
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:other),
        NetworkNode(; id="C", node_type=:other),
        NetworkNode(; id="D2", node_type=:destination),
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

# Clear any cost_scaling mutations left on the shared instances.
function reset!()
    for inst in values(_INSTANCE)
        empty!(inst.travel_time_graph.cost_scaling)
    end
    return nothing
end

end # module
