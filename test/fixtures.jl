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
        return greedy_heuristic(_instance(name, wrap_time))
    end
    return deepcopy(sol)
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
