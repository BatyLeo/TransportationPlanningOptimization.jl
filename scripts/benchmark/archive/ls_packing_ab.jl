# A/B test: TPO LS with packing=:ffd_union (current default) vs packing=:frozen
# on each benchmark instance, compared to STP.
#
# Measures iter/s, saved cost, and final cost. If :frozen iter/s catches up to
# STP and the final cost ratio stays close to baseline, that's the fix.
include(joinpath(@__DIR__, "compare_packages.jl"))

using Printf
using Dates

const INSTANCES = ["small", "medium", "large"]
const LS_LIMITS = Dict("small" => 10, "medium" => 30, "large" => 60)

function run_tpo_ls(name::String, ls_limit::Real, packing::Symbol)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")
    (; nodes, arcs, commodities) = parse_inbound_instance(nodes_file, legs_file, com_file)
    instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)

    filtering_sol = TPO.lower_bound_filtering(instance)
    sub = TPO.extract_filtered_instance(instance, filtering_sol)
    candidates = TPO.mix_greedy_and_lower_bound(sub)
    chosen = TPO.choose_best_feasible(
        [candidates.mixed, candidates.greedy, candidates.lower_bound], sub
    )
    init_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    init_cost = TPO.cost_with_nodes(init_full, instance)

    local result
    ls_time = @elapsed result = TPO.local_search!(
        chosen, sub; time_limit=ls_limit, packing=packing
    )
    ls_full = TPO.merge_solutions(filtering_sol, chosen, instance, sub)
    ls_cost = TPO.cost_with_nodes(ls_full, instance)
    feasible = TPO.is_feasible(ls_full, instance)
    return (;
        init_cost, ls_cost, ls_time, n_iter=result.n_iter, saved=result.saved, feasible
    )
end

function run_stp_ls(name::String, ls_limit::Real)
    nodes_file = joinpath(DATA_DIR, "$(name)_nodes.csv")
    legs_file = joinpath(DATA_DIR, "$(name)_legs.csv")
    com_file = joinpath(DATA_DIR, "$(name)_commodities.csv")
    instance = STP.read_instance(nodes_file, legs_file, com_file)
    instance = STP.add_properties(instance, STP.tentative_first_fit, Int[])
    filtering_sol = STP.Solution(instance)
    STP.lower_bound_filtering!(filtering_sol, instance)
    sub = STP.extract_filtered_instance(instance, filtering_sol)
    sub = STP.add_properties(sub, STP.tentative_first_fit, Int[])
    mix_sol = STP.Solution(sub)
    greedy_sol, lb_sol = STP.mix_greedy_and_lower_bound!(mix_sol, sub)
    cands = [mix_sol, greedy_sol, lb_sol]
    feas = filter(s -> STP.is_feasible(sub, s), cands)
    pool = isempty(feas) ? cands : feas
    chosen = STP.solution_deepcopy(
        pool[argmin(STP.compute_cost(sub, s) for s in pool)], sub
    )
    init_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    init_cost = STP.compute_cost(instance, init_full)
    pre_ls = STP.compute_cost(sub, chosen)
    # Capture iter count from STP's stdout line
    captured = ""
    ls_time = mktemp() do path, io
        t = @elapsed redirect_stdout(io) do
            STP.local_search!(chosen, sub; timeLimit=Int(ls_limit), verbose=false)
        end
        flush(io)
        captured = read(path, String)
        return t
    end
    m = match(r"Loop Break\s*:\s*time\s*=\s*[\d\.]+,\s*i\s*=\s*(\d+)", captured)
    n_iter = m === nothing ? -1 : parse(Int, m.captures[1])
    post_ls = STP.compute_cost(sub, chosen)
    ls_full = STP.merge_solutions(chosen, filtering_sol, instance, sub)
    ls_cost = STP.compute_cost(instance, ls_full)
    feasible = STP.is_feasible(instance, ls_full)
    return (; init_cost, ls_cost, ls_time, n_iter, saved=pre_ls - post_ls, feasible)
end

println("=== Warmup ===")
run_tpo_ls("small", 1.0, :ffd_union);
GC.gc();
run_tpo_ls("small", 1.0, :frozen);
GC.gc();
run_stp_ls("small", 1.0);
GC.gc();
println("=== Warmup done ===\n")

results = Dict{String,Dict{String,Any}}()

for name in INSTANCES
    lsl = LS_LIMITS[name]
    println("=== $name (LS budget $(lsl)s) ===")
    results[name] = Dict{String,Any}()

    println("  Running TPO :ffd_union (current default)...")
    r_union = run_tpo_ls(name, lsl, :ffd_union)
    GC.gc()
    println("  Running TPO :frozen (the experiment)...")
    r_frozen = run_tpo_ls(name, lsl, :frozen)
    GC.gc()
    println("  Running STP (reference)...")
    r_stp = run_stp_ls(name, lsl)
    GC.gc()

    results[name]["tpo_union"] = r_union
    results[name]["tpo_frozen"] = r_frozen
    results[name]["stp"] = r_stp

    @printf("\n  %-14s %12s %14s %14s\n", "metric", "TPO :union", "TPO :frozen", "STP")
    @printf(
        "  %-14s %12d %14d %14d  (iters)\n",
        "n_iter",
        r_union.n_iter,
        r_frozen.n_iter,
        r_stp.n_iter
    )
    @printf(
        "  %-14s %12.1f %14.1f %14.1f  (iter/s)\n",
        "iter/s",
        r_union.n_iter / r_union.ls_time,
        r_frozen.n_iter / r_frozen.ls_time,
        r_stp.n_iter / r_stp.ls_time
    )
    @printf(
        "  %-14s %12.1f %14.1f %14.1f  (cost saved)\n",
        "saved",
        r_union.saved,
        r_frozen.saved,
        r_stp.saved
    )
    @printf(
        "  %-14s %12.1f %14.1f %14.1f  (final LS cost)\n",
        "ls_cost",
        r_union.ls_cost,
        r_frozen.ls_cost,
        r_stp.ls_cost
    )
    @printf(
        "  %-14s %12.4f %14.4f %14s  (cost / STP)\n",
        "cost_ratio",
        r_union.ls_cost / r_stp.ls_cost,
        r_frozen.ls_cost / r_stp.ls_cost,
        "1.0000"
    )
    println()
end

println("\n=== Summary ===")
@printf(
    "%-12s %12s %12s %12s %12s %12s\n",
    "instance",
    ":union iters",
    ":frozen iters",
    "frozen/union",
    ":union cost",
    ":frozen cost"
)
for name in INSTANCES
    u = results[name]["tpo_union"]
    f = results[name]["tpo_frozen"]
    @printf(
        "%-12s %12d %12d %11.2fx %12.1f %12.1f\n",
        name,
        u.n_iter,
        f.n_iter,
        f.n_iter / u.n_iter,
        u.ls_cost,
        f.ls_cost
    )
end
