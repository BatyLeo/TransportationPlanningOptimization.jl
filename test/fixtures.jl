# Shared, memoized test fixtures. Parsing and Instance construction for the
# benchmark instances is expensive, so build each one once and reuse it.
# Instance is immutable, but solvers also write per-bundle Dijkstra scratch
# into the shared `instance.travel_time_graph.cost_matrix` (and
# `cost_scaling`, for slope scaling). Sharing instances is safe only because
# every reader either writes that scratch before reading it, or builds its
# own private instance. Tests that ASSERT on `cost_scaling` must call
# `reset!()` first (see TestFixtures.reset!).

# Ensure exactly one canonical `Main.Inbound` module exists, whether this file
# is loaded standalone (nothing pre-loaded `Inbound` yet: include it into
# Main here) or nested under `runtests.jl` (which already did
# `include("Inbound.jl")`: reuse that one). This line runs in the scope
# `fixtures.jl` is included into, which is always Main, so `TestFixtures`
# below can reference the single `Main.Inbound` via `..Inbound`. Doing the
# include from inside `module TestFixtures` instead would create a second,
# distinct `Inbound` module, and parsed values carry Inbound-specific info
# types (`InboundArcInfo`, `InboundCommodityInfo`, see test/Inbound.jl:253,
# 283) whose identity would then differ from `Main.Inbound`'s.
isdefined(Main, :Inbound) || include(joinpath(@__DIR__, "Inbound.jl"))

module TestFixtures

using TransportationPlanningOptimization
using Dates
using ..Inbound: parse_inbound_instance

const DATADIR = joinpath(@__DIR__, "public")

# name => memoized parsed (; nodes, arcs, commodities)
const _PARSED = Dict{String,Any}()
# (name, wrap_time) => memoized built Instance
const _INSTANCE = Dict{Tuple{String,Bool},Any}()
# (name, wrap_time) => memoized greedy Solution (never handed out directly)
const _GREEDY = Dict{Tuple{String,Bool},Any}()

function _parsed(name::String)
    return get!(_PARSED, name) do
        parse_inbound_instance(
            joinpath(DATADIR, "$(name)_nodes.csv"),
            joinpath(DATADIR, "$(name)_legs.csv"),
            joinpath(DATADIR, "$(name)_commodities.csv"),
        )
    end
end

function _instance(name::String, wrap_time::Bool)
    return get!(_INSTANCE, (name, wrap_time)) do
        (; nodes, arcs, commodities) = _parsed(name)
        Instance(nodes, arcs, commodities, Week(1); wrap_time=wrap_time)
    end
end

function _greedy(name::String, wrap_time::Bool)
    sol = get!(_GREEDY, (name, wrap_time)) do
        greedy_heuristic(_instance(name, wrap_time))
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
