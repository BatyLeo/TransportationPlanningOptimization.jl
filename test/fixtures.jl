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
    parents, _ = TransportationPlanningOptimization.bundle_dijkstra(
        ttg.graph, origin, ttg.cost_matrix; dst=destination
    )
    path = TransportationPlanningOptimization.trace_path(parents, origin, destination)
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

# Clear any cost_scaling mutations left on the shared instances.
function reset!()
    for inst in values(_INSTANCE)
        empty!(inst.travel_time_graph.cost_scaling)
    end
    return nothing
end

end # module
