# TPO performance optimization plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the runtime gap between `TransportationPlanningOptimization` (TPO) and `ShipperTransportationPlanning` (STP) on the inbound benchmark, focusing first on `lower_bound_filtering` and then on `local_search!`.

**Architecture:** Both phases share one bottleneck — the serial `for (u, v) in bundle_arcs` loop inside `update_bundle_cost_matrix!` (`src/algorithms/cost_matrix_update.jl:797`). STP parallelizes the equivalent loop via `OhMyThreads.@tasks`. We will port the same parallelism pattern to TPO, using a per-task `BinPackingBuffer` so the existing scratch-allocation contract is preserved. After parallelism lands, two narrower optimizations (one for filter, one for LS) close residual gaps.

**Tech Stack:** Julia 1.11+, OhMyThreads.jl (new dep), existing TPO modules.

**Baseline performance** (single-threaded, captured 2026-05-29, see `scripts/benchmark/results/comparison.csv`):

| Instance | TPO filter (s) | STP filter (s) | TPO LS iter/s | STP LS iter/s |
|---|---|---|---|---|
| small (312 bundles) | 0.39 | 0.53 | 145 | 704 |
| medium (632) | 1.83 | 1.77 | 44 | 357 |
| large (1165) | 3.33 | 2.09 | 96 | 719 |
| extra_large (2521) | 48.5 | 21.3 | 18 | 199 |

This machine has 4 cores (`Sys.CPU_THREADS = 4`). Run all post-Phase-1 benchmarks with `julia -t auto` to use them.

**Profile evidence** (medium instance, `scripts/benchmark/profile_*.jl`):
- Filter: 91% of samples are in `update_bundle_cost_matrix!` (called once per bundle by `lower_bound_filtering!`).
- LS: ~72% of samples reach `update_bundle_cost_matrix!` via `_try_reinsert_bundle!` (reintro + refine inside two-node).

Per-iteration cost-quality is already in TPO's favor (8–13x more saved per iter on small/medium/large) — this plan trades nothing on quality, only throughput.

---

## Phase 1: Parallelize `update_bundle_cost_matrix!`

The single change here lifts both filter and LS throughput in proportion to thread count.

### Task 1.1: Add `OhMyThreads` as a TPO dependency

**Files:**
- Modify: `Project.toml`

- [ ] **Step 1: Look at current deps**

Run: `julia --project -e 'using Pkg; Pkg.status()'`

Confirm `OhMyThreads` is NOT in `[deps]`.

- [ ] **Step 2: Add the dependency**

Run from `TransportationPlanningOptimization.jl/`:
```bash
julia --project -e 'using Pkg; Pkg.add("OhMyThreads")'
```

Expected: `OhMyThreads` appears in `Project.toml` `[deps]` and `[compat]`.

- [ ] **Step 3: Verify the package loads**

Run: `julia --project -e 'using OhMyThreads; println(OhMyThreads.@tasks)'`

(The expression is incomplete syntactically; we just want to confirm the macro is exported. Replace with `methods(OhMyThreads.tmap)` if you want a non-error check.)

Actual check: `julia --project -e 'using OhMyThreads; @show methods(OhMyThreads.tmap) |> first'`

- [ ] **Step 4: Commit**

```bash
git add Project.toml Manifest.toml
git commit -m "deps: add OhMyThreads for cost matrix parallelism"
```

### Task 1.2: Wire `OhMyThreads` into the TPO module

**Files:**
- Modify: `src/TransportationPlanningOptimization.jl`

- [ ] **Step 1: Read the current using-list**

Read `src/TransportationPlanningOptimization.jl:1-15`. Note that imports are written as `using X: X` for explicit re-export. Match the style.

- [ ] **Step 2: Add the import**

Edit `src/TransportationPlanningOptimization.jl`. After the `using ProgressMeter: @showprogress` line, add:
```julia
using OhMyThreads: @tasks, @local
```

- [ ] **Step 3: Verify the package precompiles**

Run: `julia --project -e 'using TransportationPlanningOptimization'`

Expected: precompile succeeds, no `LoadError`.

- [ ] **Step 4: Run the full test suite as a regression baseline**

Run: `julia --project -e 'using Pkg; Pkg.test()'`

Expected: all tests pass (this is the safety net for the changes ahead).

- [ ] **Step 5: Commit**

```bash
git add src/TransportationPlanningOptimization.jl
git commit -m "deps: import OhMyThreads macros into TPO"
```

### Task 1.3: Parallelize the `bundle_arcs` loop in `update_bundle_cost_matrix!`

The 4-arg overload at `cost_matrix_update.jl:772-817` is the hot one. The 1-arg-bundle-idx overload at `:826` just forwards to it, so we only need to edit the 4-arg version.

**Files:**
- Modify: `src/algorithms/cost_matrix_update.jl:797-815`
- Test: `test/test_lower_bound.jl` (existing — used as regression check)

- [ ] **Step 1: Read the current loop**

Read `src/algorithms/cost_matrix_update.jl:797-815`. The loop body is fully independent across `(u_code, v_code)` pairs except for:
1. Reads from `ttg.cost_matrix` sparsity pattern (read-only after the `fill!`).
2. Writes to `ttg.cost_matrix[u_code, v_code]` — distinct cells per iteration.
3. Uses `buffer` — a single shared `BinPackingBuffer` that holds mutable scratch.

The shared `buffer` is the only race. We replace it with a per-task buffer.

- [ ] **Step 2: Write a regression test that pins current behavior**

Create `test/test_parallel_cost_matrix.jl`:
```julia
using Test
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
using Dates
using SparseArrays

# Two real-world inbound instances exercised by this test (must exist in
# test/public/). Comparing serial vs parallel results on a non-trivial bundle.
isdefined(Main, :Inbound) || include(joinpath(@__DIR__, "Inbound.jl"))
using .Inbound: parse_inbound_instance

@testset "update_bundle_cost_matrix! parallel matches serial" begin
    for name in ("tiny", "small")
        nodes_file = joinpath(@__DIR__, "public", "$(name)_nodes.csv")
        legs_file = joinpath(@__DIR__, "public", "$(name)_legs.csv")
        com_file = joinpath(@__DIR__, "public", "$(name)_commodities.csv")
        (; nodes, arcs, commodities) = parse_inbound_instance(
            nodes_file, legs_file, com_file
        )
        instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
        sol = TPO.Solution(instance)
        bundle_idx = 1
        bundle = instance.bundles[bundle_idx]
        bundle_arcs = instance.travel_time_graph.bundle_arcs[bundle_idx]

        # Compute parallel result (this is what the function will do after the change).
        TPO.update_bundle_cost_matrix!(sol, instance, bundle, bundle_arcs)
        parallel_costs = Dict(
            (u, v) => instance.travel_time_graph.cost_matrix[u, v]
            for (u, v) in bundle_arcs
        )

        # Recompute serially using a fresh buffer, expectation must match.
        # We use the lower-level `compute_ttg_edge_incremental_cost` directly to
        # build the reference.
        sol2 = TPO.Solution(instance)
        buf = TPO.BinPackingBuffer()
        serial_costs = Dict{Tuple{Int,Int},Float64}()
        for (u, v) in bundle_arcs
            serial_costs[(u, v)] = TPO.compute_ttg_edge_incremental_cost(
                sol2, instance, bundle, u, v, TPO.CheapestMode();
                buffer=buf, packing=:frozen,
            )
        end

        @test length(parallel_costs) == length(serial_costs)
        for k in keys(parallel_costs)
            @test isfinite(parallel_costs[k]) == isfinite(serial_costs[k])
            if isfinite(serial_costs[k])
                @test isapprox(parallel_costs[k], serial_costs[k]; rtol=1e-10)
            end
        end
    end
end
```

Wire into the runner: edit `test/runtests.jl` and add inside the `@testset "Data Structures"` block (after the existing `Graphs` subset):
```julia
@testset "Parallel cost matrix" begin
    include("test_parallel_cost_matrix.jl")
end
```

- [ ] **Step 3: Run the new test (it should pass even before parallelization)**

Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'`

Expected: all tests including the new one pass.

This pins the *serial* baseline: the parallel implementation in Step 4 must reproduce these costs exactly.

- [ ] **Step 4: Replace the serial loop with the parallel version**

In `src/algorithms/cost_matrix_update.jl`, replace lines 797-815 with:

```julia
    # Parallelize the per-arc cost evaluation. Each task uses its own
    # BinPackingBuffer (via @local) so the scratch arrays in the buffer are
    # never shared across tasks. Writes to `ttg.cost_matrix[u_code, v_code]`
    # are safe in parallel because each iteration writes a distinct cell of
    # the sparse matrix (whose pattern is already established by `fill!`
    # above) — no allocation, no shared CSC scratch.
    @tasks for (u_code, v_code) in bundle_arcs
        @local buffer_local = BinPackingBuffer()
        su = cache.ttg_spatial[u_code]
        sv = cache.ttg_spatial[v_code]
        if (su, sv) in fa || su in fn || sv in fn
            ttg.cost_matrix[u_code, v_code] = Inf
        else
            ttg.cost_matrix[u_code, v_code] = cost_fn(
                current_solution,
                instance,
                bundle,
                u_code,
                v_code,
                mode_selector;
                buffer=buffer_local,
                packing,
            )
        end
    end
```

Note: the function signature's existing `buffer::BinPackingBuffer=BinPackingBuffer(instance)` kwarg becomes unused inside this function. **Do not delete it** — it is part of the public API surface and callers still pass it. Just don't reference it inside the loop.

Update the docstring above line 772 to mention that the buffer kwarg is now ignored in this overload and per-task buffers are created internally.

- [ ] **Step 5: Run the regression test under multithreading**

Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'`

Expected: all tests pass. The new test must still match the original serial reference values bit-for-bit (modulo rtol=1e-10), confirming no semantic regression.

- [ ] **Step 6: Run under single thread too**

Run: `julia --project --threads=1 -e 'using Pkg; Pkg.test()'`

Expected: all tests still pass. `@tasks` falls back to serial when `nthreads()==1`.

- [ ] **Step 7: Commit**

```bash
git add src/algorithms/cost_matrix_update.jl test/test_parallel_cost_matrix.jl test/runtests.jl
git commit -m "perf: parallelize bundle_arcs loop in update_bundle_cost_matrix!"
```

### Task 1.4: Measure the speedup with the comparison benchmark

**Files:**
- Use: `scripts/benchmark/run_comparison.jl`

- [ ] **Step 1: Re-run the comparison benchmark with 4 threads**

Run:
```bash
rm scripts/benchmark/results/comparison.csv scripts/benchmark/results/comparison.md
julia --project=scripts --threads=4 scripts/benchmark/run_comparison.jl 2>&1 | tee scripts/benchmark/results/phase1.log
```

Expected: filter and LS times improve substantially over the baseline above. The expected per-instance filter and LS iter/s targets (based on 4-thread linear speedup over the bundle_arcs loop, discounting Amdahl overhead):

| Instance | Filter target (s) | LS iter/s target |
|---|---|---|
| small | 0.15-0.25 | 400-600 |
| medium | 0.7-1.2 | 150-300 |
| large | 1.0-1.5 | 350-500 |
| extra_large | 14-22 | 60-100 |

If filter and iter/s improve by 2.5-3.5x, parallelism is working. If improvement is < 1.5x, investigate (likely culprits: per-arc work too small to amortize task overhead; sparse-matrix write contention; or `@tasks` defaulting to too-fine-grained chunks).

- [ ] **Step 2: Compare against STP and document**

Append a short paragraph to `scripts/benchmark/results/phase1.log` summarizing TPO vs STP filter and LS iter/s post-parallelism. Specifically check: does TPO filter on extra_large now beat or match STP's 21s? Does LS iter/s gap close on extra_large?

- [ ] **Step 3: Commit the new results**

```bash
git add scripts/benchmark/results/
git commit -m "bench: record Phase 1 (parallel cost matrix) results"
```

---

## Phase 2: Reduce filter-specific overhead

After Phase 1, filter still has roughly 8% of time in the per-arc `_sum_lb_incremental_cost` reduction over the cost tuple, plus 5% in `Base.sum`. The user-defined Inbound cost types (`CarbonArcCost`, `StockArcCost`, `NodeVolumeCost`) each do their own `sum(c.size for c in comms)` walk over the commodity list. If the input commodity list is the same across all three cost components — which it is — we can pass it once and amortize the iteration.

### Task 2.1: Profile filter again post-Phase-1 to confirm the next bottleneck

**Files:**
- Use: `scripts/benchmark/profile_filter.jl`

- [ ] **Step 1: Re-run the filter profile under 4 threads**

Run: `julia --project=scripts --threads=4 scripts/benchmark/profile_filter.jl 2>&1 | tee scripts/benchmark/results/filter_profile_phase1.txt`

- [ ] **Step 2: Inspect the new top consumers**

Look at the flat profile's top 15 entries by self time. If `_sum_lb_incremental_cost` (`src/instance/graphs/sum_arc_cost.jl:84`) and `Inbound.lower_bound_incremental_cost` together still account for > 20% of time, Task 2.2 is worth doing. If they have already shrunk into the noise, skip to Phase 3.

- [ ] **Step 3: Commit the profile**

```bash
git add scripts/benchmark/results/filter_profile_phase1.txt
git commit -m "bench: record post-Phase-1 filter profile"
```

### Task 2.2: Specialize `SumArcCost.lower_bound_incremental_cost` to avoid per-component commodity iteration

**Files:**
- Modify: `src/instance/graphs/sum_arc_cost.jl:76-90`

- [ ] **Step 1: Read the current implementation**

Read `src/instance/graphs/sum_arc_cost.jl:60-110` to understand the current `_sum_lb_incremental_cost` and how it delegates to each cost component in the tuple.

- [ ] **Step 2: Write a regression test before refactoring**

Create `test/test_sum_arc_cost_inbound.jl`:
```julia
using Test
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization
isdefined(Main, :Inbound) || include(joinpath(@__DIR__, "Inbound.jl"))
using .Inbound: CarbonArcCost, StockArcCost, NodeVolumeCost, InboundCommodityInfo

@testset "SumArcCost lower_bound_incremental_cost on Inbound tuple" begin
    # Synthetic commodities matching the Inbound profile (stock_cost in info)
    comms = [
        TPO.LightCommodity(;
            origin_id="A", destination_id="B", size=10.0, quantity=1,
            arrival_date=DateTime(2025, 1, 1), max_delivery_time=Day(1),
            info=InboundCommodityInfo(2.0),
        ),
        TPO.LightCommodity(;
            origin_id="A", destination_id="B", size=5.0, quantity=1,
            arrival_date=DateTime(2025, 1, 1), max_delivery_time=Day(1),
            info=InboundCommodityInfo(3.0),
        ),
    ]
    cost_tuple = (
        TPO.LinearArcCost(0.5),
        CarbonArcCost(0.1),
        StockArcCost(100.0),
    )
    sum_cost = TPO.SumArcCost(cost_tuple)
    new_comms = comms[1:1]
    # Reference: compute by summing each component separately.
    expected = sum(
        TPO.lower_bound_incremental_cost(c, comms, new_comms) for c in cost_tuple
    )
    got = TPO.lower_bound_incremental_cost(sum_cost, comms, new_comms)
    @test isapprox(got, expected; rtol=1e-10)
end
```

Wire into `test/runtests.jl` in the `SumArcCost` block.

Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'` — must pass.

- [ ] **Step 3: Inspect what the tuple iteration costs**

If the profile shows the bulk of cost is `Base.sum` over the tuple, the simplest specialization is unrolling. If the bulk is the per-component `sum(c.size for c in comms)`, the right specialization is to compute `total_size = sum_size(comms)` once and pass it. Pick based on the Step 1 profile.

Pick the strategy:
- **(a) If per-component iteration over `comms` dominates:** Modify each Inbound cost type's `lower_bound_incremental_cost` to accept a precomputed `total_size` keyword and have `_sum_lb_incremental_cost` pass it.
- **(b) If tuple iteration overhead dominates:** Unroll the tuple by writing a generated function or `@generated` body that statically expands the per-element sum.

This step is a decision point, not code. Document the choice in the next step's commit message.

- [ ] **Step 4: Implement the chosen strategy**

(For strategy (a) — most likely the winner.) Modify `_sum_lb_incremental_cost`:

```julia
function _sum_lb_incremental_cost(
    cost_tuple::Tuple, existing::Vector{C}, new::Vector{C}
) where {C<:LightCommodity}
    # Compute the merged-size aggregates once and reuse across every cost
    # component. Previously each component re-iterated `existing` and `new`
    # to compute the same sum.
    existing_size = isempty(existing) ? 0.0 : sum(c.size for c in existing)
    new_size = isempty(new) ? 0.0 : sum(c.size for c in new)
    total = 0.0
    for c in cost_tuple
        total += lower_bound_incremental_cost(c, existing, new;
                                              existing_size, new_size)
    end
    return total
end
```

Add the optional keyword to each component's `lower_bound_incremental_cost`:

```julia
function lower_bound_incremental_cost(
    c::LinearArcCost, existing::Vector{C}, new::Vector{C};
    existing_size::Float64=sum(x.size for x in existing; init=0.0),
    new_size::Float64=sum(x.size for x in new; init=0.0),
) where {C<:LightCommodity}
    return c.unit_cost * (existing_size + new_size)
end
```

Do the same for the Inbound types (in `test/Inbound.jl`). The default-keyword fallback preserves backward compatibility for any external caller still passing only positional args.

Note: this requires editing `test/Inbound.jl` too, since the Inbound types are defined there.

- [ ] **Step 5: Run the regression test**

Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'`

Expected: all tests pass.

- [ ] **Step 6: Re-run the filter benchmark and check the gain**

Run:
```bash
rm scripts/benchmark/results/comparison.csv scripts/benchmark/results/comparison.md
julia --project=scripts --threads=4 scripts/benchmark/run_comparison.jl 2>&1 | tee scripts/benchmark/results/phase2.log
```

Expected: filter time drops further. If the change had no measurable effect (< 5%), revert and skip.

- [ ] **Step 7: Commit**

```bash
git add src/instance/graphs/sum_arc_cost.jl test/Inbound.jl test/test_sum_arc_cost_inbound.jl test/runtests.jl scripts/benchmark/results/
git commit -m "perf: precompute commodity-size aggregates in SumArcCost LB path"
```

---

## Phase 3: Reduce LS-specific overhead

After Phase 1, LS iter/s should be much closer to STP. The remaining gap (if any) will be visible in the `_try_reinsert_bundle!` refine loop inside two-node: it does a full `update_bundle_cost_matrix!` + Dijkstra per lifted bundle. The two cheapest pieces of low-hanging fruit:

### Task 3.1: Profile LS post-Phase-1 to confirm next bottleneck

**Files:**
- Use: `scripts/benchmark/profile_ls.jl`

- [ ] **Step 1: Re-run the LS profile under 4 threads**

Run: `PROFILE_INSTANCE=large julia --project=scripts --threads=4 scripts/benchmark/profile_ls.jl 2>&1 | tee scripts/benchmark/results/ls_profile_phase1.txt`

(Use `large` instead of `medium` so the LS iters/s number is meaningful at the same scale we saw the throughput gap.)

- [ ] **Step 2: Inspect the new top consumers**

The relevant question: is `update_bundle_cost_matrix!` still the top consumer (now bottlenecked by Amdahl on a per-arc basis), or has the bottleneck shifted to `add_bundle_path!` / `remove_bundle_path!` (which do not parallelize internally)?

- **If `update_bundle_cost_matrix!` is still > 50% of LS time:** the per-arc work is too coarse for 4-thread parallelism, OR there's a hot inner sparse-array operation. Proceed to Task 3.2.
- **If `add_bundle_path!` and `_remove_commodities` jumped to the top:** they were hidden behind cost matrix work before. Proceed to Task 3.3.
- **If LS final-cost ratio is now < 1.0 on all four instances:** stop — the gap is closed.

- [ ] **Step 3: Commit the profile**

```bash
git add scripts/benchmark/results/ls_profile_phase1.txt
git commit -m "bench: record post-Phase-1 LS profile"
```

### Task 3.2: If `update_bundle_cost_matrix!` is still the bottleneck — eliminate sparse-matrix inner-loop overhead

The pre-Phase-1 profile showed ~17% of total LS samples in `SparseArrays.getindex` on the bin matrix, deep inside `ffd_cost`. After Phase 1 parallelizes the outer loop, this inner cost remains per-arc. The fix: switch `ffd_cost`'s bin-row lookup from sparse-matrix indexing to a dense per-arc vector.

**Files:**
- Modify: `src/instance/bin.jl` (around `ffd_count!` and the bin-cost helper).
- Read first: `src/instance/bin.jl:61-100` to understand the current ffd_count signature; `src/algorithms/cost_matrix_update.jl:115-200` to see how `incremental_cost` calls into bins; `src/solution/solution.jl` for the sparse `bins` storage.

- [ ] **Step 1: Read the relevant code**

Read `src/instance/bin.jl:25-100`, `src/algorithms/cost_matrix_update.jl:100-200`, and the `bins_of` accessor. Map exactly where the sparse `getindex` happens (likely inside `incremental_cost` when iterating over existing bins on an arc).

- [ ] **Step 2: Write a microbenchmark**

Create `benchmark/bench_ffd_inner.jl`:
```julia
using BenchmarkTools
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

# Build a representative arc's commodity list and measure `ffd_count!` plus the
# upstream `incremental_cost` cost on a synthetic input.
# (Fill in with realistic sizes/capacities from the medium instance once
# observed; report the @btime number before and after the optimization.)
```

Use the existing `benchmark/benchmarks.jl` as a template. Goal: a single timing number we can compare before/after.

- [ ] **Step 3: Replace the sparse lookup with a buffered dense view**

The exact code change depends on what you find in Step 1. The general shape: introduce a `Vector{Bin}` cache field on `BinPackingBuffer` (or pass a dense view as an argument), populate it once per arc from the sparse `bins[arc_index]`, and have `incremental_cost` read from the dense vector instead of the sparse matrix.

Write the change so the dense buffer is local to the call (preserves the per-task safety from Phase 1).

- [ ] **Step 4: Run the test suite to catch regressions**

Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'`

Expected: all tests pass.

- [ ] **Step 5: Re-run the LS benchmark**

Run: `julia --project=scripts --threads=4 scripts/benchmark/run_comparison.jl 2>&1 | tee scripts/benchmark/results/phase3a.log`

Expected: LS iter/s improves further. Targets: extra_large LS iter/s > 100, large LS iter/s > 500.

- [ ] **Step 6: Commit**

```bash
git add src/instance/bin.jl benchmark/bench_ffd_inner.jl scripts/benchmark/results/
git commit -m "perf: cache bins in dense buffer to avoid sparse getindex in ffd"
```

### Task 3.3: If `add_bundle_path!` / `_remove_commodities` is the new bottleneck — reuse `_drain_first_n` dict lookups

The Phase 0 LS profile showed `Dict.ht_keyindex` at ~2,200 samples (5% of total) inside `_drain_first_n` (called from `_remove_commodities`). After Phase 1, this becomes a higher fraction. The fix: swap the `Dict{LightCommodity, ...}` keying for an `IdDict` or for a small-vector linear scan, depending on the bundle's commodity count.

**Files:**
- Modify: `src/solution/solution.jl` (around `_drain_first_n` and the `assignments` dict).
- Read first: `src/solution/solution.jl:756-830` to understand the current implementation.

- [ ] **Step 1: Read the current implementation**

Read `src/solution/solution.jl:740-830`. Note that `_drain_first_n` operates on a per-arc bin's commodity list and looks up each commodity in a dict keyed by `LightCommodity`.

- [ ] **Step 2: Choose the replacement strategy**

If commodity counts per arc are typically < ~50 (check by adding `@show length` debug print in `_drain_first_n` and running medium), a linear scan over a `Vector{Pair{LightCommodity,Int}}` is faster than a hash lookup because of cache locality. If counts are typically > 200, an `IdDict` (identity-based hashing — avoids the equality check) is the right move.

- [ ] **Step 3: Write a unit test pinning current behavior**

Create `test/test_drain_first_n.jl` with a few hand-built calls comparing input/output. Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'`.

- [ ] **Step 4: Implement the replacement**

Modify the data structure and update all callers. Keep the public API of `_drain_first_n` and `_remove_commodities` unchanged.

- [ ] **Step 5: Run tests**

Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'`

Expected: all tests pass, including the new one.

- [ ] **Step 6: Re-run the LS benchmark**

Run: `julia --project=scripts --threads=4 scripts/benchmark/run_comparison.jl 2>&1 | tee scripts/benchmark/results/phase3b.log`

- [ ] **Step 7: Commit**

```bash
git add src/solution/solution.jl test/test_drain_first_n.jl test/runtests.jl scripts/benchmark/results/
git commit -m "perf: replace LightCommodity Dict with cache-friendly structure"
```

---

## Phase 4: Final verification

### Task 4.1: Run the full cross-package comparison test suite

**Files:**
- Use: existing `test/test_compare_to_shipper.jl`

- [ ] **Step 1: Re-run with 4 threads**

Run: `julia --project --threads=4 -e 'using Pkg; Pkg.test()'`

Expected: every cross-package assertion still holds (path equality on endpoints, cost-ratio tolerances on tiny/small).

- [ ] **Step 2: Re-run with 1 thread**

Run: `julia --project --threads=1 -e 'using Pkg; Pkg.test()'`

Expected: same — parallelism must not change single-thread results.

### Task 4.2: Generate the final comparison report

**Files:**
- Use: `scripts/benchmark/run_comparison.jl`

- [ ] **Step 1: Final benchmark run, 4 threads**

Run:
```bash
rm scripts/benchmark/results/comparison.csv scripts/benchmark/results/comparison.md
julia --project=scripts --threads=4 scripts/benchmark/run_comparison.jl 2>&1 | tee scripts/benchmark/results/final.log
```

- [ ] **Step 2: Update the project README** (if relevant)

Append a perf table to `README.md` showing the before/after numbers from this work. Skip if the README is already documentation-heavy or if the numbers are unstable.

- [ ] **Step 3: Final commit**

```bash
git add scripts/benchmark/results/ README.md
git commit -m "bench: final TPO/STP comparison after perf optimization"
```

---

## Success criteria

The plan is successful when **all four instances** show:
- **filter (TPO) ≤ filter (STP)** under `julia --threads=4`
- **LS iter/s (TPO) ≥ 0.5 × LS iter/s (STP)** (closing half the gap is enough given TPO's 8-13x per-iter quality advantage)
- **LS final cost ratio (TPO/STP) ≤ 1.005** on all four instances

If Phase 1 alone achieves all three, Phases 2 and 3 are optional. The profile in each phase decides whether to keep going.

## Out of scope

- Multi-threading correctness changes outside `update_bundle_cost_matrix!`. No other function is parallelized in this plan.
- The `lower_bound` (non-filtering) algorithm, or `greedy_heuristic`. Both are profiled separately and not on the critical path for the inbound benchmark.
- The `local_search!` acceptance criterion. TPO's strict-improvement threshold has been validated as a quality advantage and should stay.
- Gurobi-extension changes. License renewal is a separate concern.
