# Benchmark: Dict vs SparseMatrixCSC for the Solution assignment store.
#
# We take a real, greedy-populated Solution, extract its (u_tsg, v_tsg) -> assignment
# entries, and compare the two storage strategies on the operations that matter:
#   1. Construction  (build the store from the edge/value triplets)
#   2. Random access (getindex on a shuffled key list -> the add/remove hot path)
#   3. Full sweep    (sum cost over all entries -> cost/feasibility passes)
# Plus the in-memory footprint of each store.
#
# Run:  julia --project=test scripts/benchmark/bench_assignments_store.jl

using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using Graphs: Graphs
using SparseArrays
using BenchmarkTools
using Random
using Printf
using Dates

# Cap the measurement budget so large instances can't run away.
BenchmarkTools.DEFAULT_PARAMETERS.seconds = 2.0

isdefined(Main, :Inbound) || include(joinpath(@__DIR__, "..", "..", "test", "Inbound.jl"))
using .Inbound

const DATA = joinpath(@__DIR__, "..", "..", "data", "inbound")

function load_instance(name)
    (; nodes, arcs, commodities) = Inbound.parse_inbound_instance(
        joinpath(DATA, "$(name)_nodes.csv"),
        joinpath(DATA, "$(name)_legs.csv"),
        joinpath(DATA, "$(name)_commodities.csv"),
    )
    return TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
end

function build_csc(keys, vals, n_tsg, V)
    us = [k[1] for k in keys]
    vs = [k[2] for k in keys]
    return sparse(us, vs, Vector{V}(vals), n_tsg, n_tsg)
end

sweep_dict(d) = sum(TPO.cost_of(a) for a in values(d); init=0.0)
function sweep_csc(A)
    s = 0.0
    vals = nonzeros(A)
    @inbounds for i in eachindex(vals)
        s += TPO.cost_of(vals[i])
    end
    return s
end

function access_dict(d, order_keys)
    s = 0.0
    @inbounds for k in order_keys
        s += TPO.cost_of(d[k])
    end
    return s
end
function access_csc(A, order_keys)
    s = 0.0
    @inbounds for k in order_keys
        s += TPO.cost_of(A[k[1], k[2]])
    end
    return s
end

function run(name)
    print("[$name] loading + greedy... ")
    flush(stdout)
    instance = load_instance(name)
    sol = TPO.greedy_heuristic(instance)
    d = sol.assignments
    V = valtype(d)
    n_tsg = Graphs.nv(instance.time_space_graph.graph)

    keys_vec = collect(keys(d))
    vals_vec = [d[k] for k in keys_vec]
    nnz_ = length(keys_vec)
    A = build_csc(keys_vec, vals_vec, n_tsg, V)

    @assert isapprox(sweep_dict(d), sweep_csc(A); rtol=1e-9)
    @assert isapprox(sweep_dict(d), TPO.cost(sol); rtol=1e-9)

    rng = MersenneTwister(1)
    shuffled = shuffle(rng, keys_vec)
    us_us, us_vs = [k[1] for k in keys_vec], [k[2] for k in keys_vec]

    print("benchmarking... ")
    flush(stdout)
    t_build_dict = @belapsed Dict(zip($keys_vec, $vals_vec))
    t_build_csc = @belapsed sparse($us_us, $us_vs, Vector{$V}($vals_vec), $n_tsg, $n_tsg)
    t_sweep_dict = @belapsed sweep_dict($d)
    t_sweep_csc = @belapsed sweep_csc($A)
    t_acc_dict = @belapsed access_dict($d, $shuffled)
    t_acc_csc = @belapsed access_csc($A, $shuffled)
    mem_dict = Base.summarysize(d)
    mem_csc = Base.summarysize(A)
    println("done")

    println("==================== instance: $name ====================")
    @printf(
        "TSG nodes (n): %d   stored arcs (nnz): %d   fill: %.4f%%\n",
        n_tsg,
        nnz_,
        100 * nnz_ / (Float64(n_tsg)^2),
    )
    println("value type: ", V)
    @printf("%-14s %14s %14s %10s\n", "operation", "Dict", "SparseCSC", "speedup")
    function row(op, td, tc)
        @printf("%-14s %12.3f µs %12.3f µs %9.2fx\n", op, td * 1e6, tc * 1e6, td / tc)
    end
    row("construct", t_build_dict, t_build_csc)
    row("sweep", t_sweep_dict, t_sweep_csc)
    row("access", t_acc_dict, t_acc_csc)
    @printf(
        "%-14s %12.2f KB %12.2f KB %9.2fx\n",
        "memory",
        mem_dict / 1024,
        mem_csc / 1024,
        mem_dict / mem_csc,
    )
    println()
    flush(stdout)
    return nothing
end

for name in ["medium", "large", "extra_large"]
    try
        run(name)
    catch err
        println("\n[$name] skipped: ", err)
        flush(stdout)
    end
end
