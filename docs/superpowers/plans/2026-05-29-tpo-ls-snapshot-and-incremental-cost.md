# TPO LS — snapshot-based revert + incremental cost tracking

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the two largest remaining single-threaded LS overheads in TPO: the two-node revert path (~22% of LS time per the `:frozen` profile, redoes the whole move) and the `cost(sol)` calls in two-node (each O(|assignments|)). Plus a small micro-optimization on the linear drain path.

**Architecture:** Add a transactional snapshot mechanism. Before any mutation inside a two-node move, lazily snapshot each touched assignment. On reject, restore from snapshot in O(touched arcs). On accept, throw the snapshot away. The accept decision becomes incremental: sum the per-call cost deltas (already returned by every primitive) instead of calling `cost(sol)` twice. Parallelism is explicitly out of scope.

**Tech Stack:** Julia 1.11+, existing TPO modules; no new dependencies.

**Baseline (post drain+merge changes, 2026-05-29)** — `scripts/benchmark/results/comparison.csv`:

| Instance | TPO LS iter/s | STP LS iter/s | TPO/STP | LS final cost ratio |
|---|---|---|---|---|
| small | 256 | 692 | 0.37x | 1.0007 |
| medium | 49 | 312 | 0.16x | 1.0068 |
| large | 129 | 640 | 0.20x | 0.9975 |

**Profile evidence** (`scripts/benchmark/profile_ls_frozen.jl`, large, 30s, packing=`:frozen`):
- Two-node revert path (`two_node_consolidation.jl:231-234`): ~22% of LS samples.
- `cost(sol)` calls inside two-node (lines 193 and 226): O(|assignments|) each, two per move.
- `_drain_first_matches_linear!` allocates `BitVector` + `Vector` per call; ~70 calls per LS iter.

**Success criteria after the three phases:**
- LS iter/s ≥ 1.5x current on each instance.
- LS final cost ratio vs STP ≤ current bound + 0.002.
- All existing tests pass single-threaded; `test_compare_to_shipper.jl` cross-package assertions hold.

---

## Phase 0 — Re-profile and pin the current baseline

Before changing anything, capture the current profile shape so each phase has a numeric target.

### Task 0.1: Capture current LS profile on large

**Files:**
- Use: `scripts/benchmark/profile_ls_frozen.jl`

- [ ] **Step 1: Run the profile**

Run:
```bash
PROFILE_INSTANCE=large PROFILE_BUDGET=30 julia --project=scripts \
  scripts/benchmark/profile_ls_frozen.jl 2>&1 \
  | tee scripts/benchmark/results/ls_profile_phase0.txt
```

Expected: completes in ~35s; produces a flat profile + tree + function-frame counts.

- [ ] **Step 2: Record the buckets we care about**

Open `scripts/benchmark/results/ls_profile_phase0.txt` and write into a new file `scripts/benchmark/results/phase_targets.md`:
```markdown
# Targets — measured on large packing=:frozen, 30s budget

| Bucket | % of LS samples |
|---|---|
| two-node revert (file:`two_node_consolidation.jl`, line 231 frame) | ___% |
| `cost(sol)` (function `cost`, called from two-node at lines 193 / 226) | ___% |
| `update_bundle_cost_matrix!` (total across reintro+two-node) | ___% |
| `remove_bundle_path!` (post drain/merge fixes) | ___% |

Iter/s observed: ___ iter/s.
```

Fill in the percentages from the profile.

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark/results/ls_profile_phase0.txt scripts/benchmark/results/phase_targets.md
git commit -m "bench: pin LS profile baseline before snapshot/incremental work"
```

---

## Phase 1 — Snapshot-based fast revert in two-node

### Task 1.1: Define the `Snapshot` type and helpers

**Files:**
- Modify: `src/solution/solution.jl` (insert near `_ensure_sorted!` and the existing assignment helpers).

- [ ] **Step 1: Write the failing tests first**

Create `test/test_snapshot_revert.jl`:
```julia
using Test
using TransportationPlanningOptimization
using Dates
const TPO = TransportationPlanningOptimization

isdefined(Main, :Inbound) || include(joinpath(@__DIR__, "Inbound.jl"))
using .Inbound: parse_inbound_instance

function _mk_sol_from_inbound(name::String)
    here = @__DIR__
    nodes = joinpath(here, "public", "$(name)_nodes.csv")
    legs = joinpath(here, "public", "$(name)_legs.csv")
    coms = joinpath(here, "public", "$(name)_commodities.csv")
    (; nodes, arcs, commodities) = parse_inbound_instance(nodes, legs, coms)
    instance = TPO.Instance(nodes, arcs, commodities, Week(1); wrap_time=true)
    sol = TPO.greedy_heuristic(instance)
    return sol, instance
end

@testset "Snapshot / snapshot_edge! / restore_from_snapshot!" begin
    @testset "snapshot_edge! on existing assignment is a deepcopy" begin
        sol, instance = _mk_sol_from_inbound("tiny")
        edge = first(keys(sol.assignments))
        snap = TPO.Snapshot{eltype(instance.bundles[1].orders[1].commodities)}()
        TPO.snapshot_edge!(snap, sol, edge)
        @test haskey(snap, edge)
        # Mutate the live assignment.
        sol.assignments[edge].cost = -42.0
        @test snap[edge].cost != -42.0  # snapshot is independent
    end

    @testset "snapshot_edge! on missing edge stores nothing" begin
        sol, instance = _mk_sol_from_inbound("tiny")
        snap = TPO.Snapshot{eltype(instance.bundles[1].orders[1].commodities)}()
        edge = (typemax(Int) - 1, typemax(Int))
        @test !haskey(sol.assignments, edge)
        TPO.snapshot_edge!(snap, sol, edge)
        @test haskey(snap, edge)
        @test snap[edge] === nothing
    end

    @testset "snapshot_edge! is idempotent" begin
        sol, instance = _mk_sol_from_inbound("tiny")
        edge = first(keys(sol.assignments))
        snap = TPO.Snapshot{eltype(instance.bundles[1].orders[1].commodities)}()
        TPO.snapshot_edge!(snap, sol, edge)
        original_assignment_cost = snap[edge].cost
        sol.assignments[edge].cost = -42.0
        # Second snapshot must not overwrite with the now-corrupted state.
        TPO.snapshot_edge!(snap, sol, edge)
        @test snap[edge].cost == original_assignment_cost
    end

    @testset "restore_from_snapshot! puts the world back" begin
        sol, instance = _mk_sol_from_inbound("tiny")
        edge = first(keys(sol.assignments))
        snap = TPO.Snapshot{eltype(instance.bundles[1].orders[1].commodities)}()
        TPO.snapshot_edge!(snap, sol, edge)
        original_cost = snap[edge].cost
        sol.assignments[edge].cost = -42.0
        TPO.restore_from_snapshot!(sol, snap)
        @test sol.assignments[edge].cost == original_cost
    end

    @testset "restore_from_snapshot! deletes edges that did not exist at snapshot time" begin
        sol, instance = _mk_sol_from_inbound("tiny")
        snap = TPO.Snapshot{eltype(instance.bundles[1].orders[1].commodities)}()
        edge = (typemax(Int) - 1, typemax(Int))
        TPO.snapshot_edge!(snap, sol, edge)  # records `nothing`
        # Pretend we added an assignment after snapshot.
        sol.assignments[edge] = TPO.SingleAssignment{
            eltype(instance.bundles[1].orders[1].commodities)
        }()
        TPO.restore_from_snapshot!(sol, snap)
        @test !haskey(sol.assignments, edge)
    end
end
```

Wire into `test/runtests.jl` inside the `Data Structures` block (after `IndexCache`):
```julia
@testset "Snapshot/restore" begin
    include("test_snapshot_revert.jl")
end
```

Run: `julia --project=scripts test/test_snapshot_revert.jl`
Expected: ERRORs (`Snapshot`, `snapshot_edge!`, `restore_from_snapshot!` not defined).

- [ ] **Step 2: Add the type alias and helpers**

In `src/solution/solution.jl`, after the `_ensure_sorted!` definition (currently ends around line 297), insert:
```julia
"""
$TYPEDSIGNATURES

Transactional snapshot of TSG-edge assignments. Maps `edge → snapshot`
where `snapshot` is either a `deepcopy` of the assignment that was present
at snapshot time (`SingleAssignment{C}` or `MultiAssignment{C}`), or
`nothing` to mean "no assignment existed at snapshot time" (so restore
will `delete!` the edge).

Use via `snapshot_edge!` (lazy, idempotent) before any in-place mutation,
and `restore_from_snapshot!` to roll back.
"""
const Snapshot{C} = Dict{Tuple{Int,Int},Union{Nothing,AbstractArcAssignment{C}}}

"""
$TYPEDSIGNATURES

Lazily snapshot the assignment at `edge`. No-op if `edge` is already in
`snapshot` (preserves the *first* state we saw, which is the pre-move state
since later mutations always come after a first snapshot).
"""
function snapshot_edge!(
    snapshot::Snapshot{C}, sol::Solution{C}, edge::Tuple{Int,Int}
) where {C}
    haskey(snapshot, edge) && return nothing
    snapshot[edge] = if haskey(sol.assignments, edge)
        deepcopy(sol.assignments[edge])
    else
        nothing
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Restore every snapshotted edge to its pre-move state. For edges whose
snapshot value is `nothing`, the assignment dict entry is deleted.
"""
function restore_from_snapshot!(sol::Solution{C}, snapshot::Snapshot{C}) where {C}
    for (edge, snap) in snapshot
        if snap === nothing
            delete!(sol.assignments, edge)
        else
            sol.assignments[edge] = snap
        end
    end
    return nothing
end
```

- [ ] **Step 3: Run the test**

Run: `julia --project=scripts test/test_snapshot_revert.jl`
Expected: 5 testsets pass.

- [ ] **Step 4: Commit**

```bash
git add src/solution/solution.jl test/test_snapshot_revert.jl test/runtests.jl
git commit -m "feat: Snapshot type + snapshot_edge!/restore_from_snapshot! helpers"
```

### Task 1.2: Add `snapshot` kwarg to `remove_bundle_path!` and `add_bundle_path!`

**Files:**
- Modify: `src/solution/solution.jl` — `add_bundle_path!` (line 707) and `remove_bundle_path!` (line 781).

- [ ] **Step 1: Write a test that pins the snapshot interception behavior**

Append to `test/test_snapshot_revert.jl`:
```julia
@testset "remove_bundle_path! with snapshot captures touched assignments" begin
    sol, instance = _mk_sol_from_inbound("tiny")
    C = eltype(instance.bundles[1].orders[1].commodities)
    bundle_idx = 1
    path = sol.bundle_paths[bundle_idx]
    @test !isempty(path)
    snap = TPO.Snapshot{C}()
    TPO.remove_bundle_path!(sol, instance, bundle_idx; snapshot=snap)
    # Every TSG edge along bundle 1's path must be in the snapshot.
    cache = instance.index_cache
    for order in instance.bundles[bundle_idx].orders
        for k in 1:(length(path) - 1)
            u_tsg = TPO.project_to_time_space_graph(path[k], order, instance)
            v_tsg = TPO.project_to_time_space_graph(path[k + 1], order, instance)
            @test haskey(snap, (u_tsg, v_tsg))
        end
    end
end

@testset "add_bundle_path! with snapshot captures touched assignments" begin
    sol, instance = _mk_sol_from_inbound("tiny")
    C = eltype(instance.bundles[1].orders[1].commodities)
    bundle_idx = 1
    saved_path = copy(sol.bundle_paths[bundle_idx])
    # Remove first so we can re-add and watch the snapshot grow.
    TPO.remove_bundle_path!(sol, instance, bundle_idx)
    snap = TPO.Snapshot{C}()
    TPO.add_bundle_path!(sol, instance, bundle_idx, saved_path; snapshot=snap)
    @test !isempty(snap)
end

@testset "no snapshot kwarg = legacy behavior (no Dict allocation)" begin
    sol, instance = _mk_sol_from_inbound("tiny")
    bundle_idx = 1
    delta = TPO.remove_bundle_path!(sol, instance, bundle_idx)
    @test delta <= 0.0
end
```

Run: `julia --project=scripts test/test_snapshot_revert.jl`
Expected: 3 new testsets FAIL because the kwarg doesn't exist yet (`MethodError` or "unrecognized keyword").

- [ ] **Step 2: Modify `add_bundle_path!`**

Edit `src/solution/solution.jl:707-746`. Change the signature to:
```julia
function add_bundle_path!(
    current_solution::Solution{C},
    instance::Instance,
    bundle_idx::Int,
    path::Vector{Int};
    mode_selector::AbstractModeSelector=CheapestMode(),
    packing::Symbol=:frozen,
    snapshot::Union{Nothing,Snapshot{C}}=nothing,
) where {C}
```

Inside the inner double loop, **before** the `cost_delta += _add_order_to_assignment!(...)` call, insert:
```julia
            snapshot !== nothing && snapshot_edge!(snapshot, current_solution, edge)
```

So the inner body becomes:
```julia
    for order in bundle.orders
        for k in 1:(length(path) - 1)
            u_tsg = project_to_time_space_graph(path[k], order, instance)
            v_tsg = project_to_time_space_graph(path[k + 1], order, instance)
            su = cache.tsg_spatial[u_tsg]
            sv = cache.tsg_spatial[v_tsg]
            arc = cache.arc_of[(su, sv)]
            edge = (u_tsg, v_tsg)
            snapshot !== nothing && snapshot_edge!(snapshot, current_solution, edge)
            cost_delta += _add_order_to_assignment!(
                current_solution.assignments,
                edge,
                arc,
                order.commodities,
                mode_selector;
                packing,
            )
        end
    end
```

- [ ] **Step 3: Modify `remove_bundle_path!`**

Edit `src/solution/solution.jl:781`. Change the signature to:
```julia
function remove_bundle_path!(
    current_solution::Solution{C}, instance::Instance, bundle_idx::Int;
    snapshot::Union{Nothing,Snapshot{C}}=nothing,
) where {C}
```

Inside the inner double loop (around line 738), insert the same guarded snapshot call before the `_remove_commodities_from_assignment!` call:
```julia
            edge = (u_tsg, v_tsg)
            snapshot !== nothing && snapshot_edge!(snapshot, current_solution, edge)
            assignment = current_solution.assignments[edge]
            cost_delta += _remove_commodities_from_assignment!(
                assignment, arc, order.commodities
            )
```

- [ ] **Step 4: Run the snapshot tests**

Run: `julia --project=scripts test/test_snapshot_revert.jl`
Expected: all testsets pass.

- [ ] **Step 5: Run existing tests (no behavioral regression without snapshot)**

Run:
```bash
julia --project=scripts -e '
include("test/Inbound.jl"); using .Inbound
include("test/test_solution.jl")
include("test/test_solution_removal.jl")
include("test/test_insertion.jl")
include("test/test_two_node_consolidation.jl")
include("test/test_local_search.jl")
'
```
Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add src/solution/solution.jl test/test_snapshot_revert.jl
git commit -m "feat: optional snapshot kwarg on remove/add_bundle_path!"
```

### Task 1.3: Forward the snapshot through `_try_reinsert_bundle!`

**Files:**
- Modify: `src/algorithms/local_search.jl:131-177`.

- [ ] **Step 1: Read the function**

Read `src/algorithms/local_search.jl:131-177`. Note the four call sites inside the function:
- Line 142: `cost_removed = remove_bundle_path!(...)` (first remove)
- Line 150: `add_bundle_path!(...)` (fallback for empty Dijkstra path)
- Line 154: `cost_added = add_bundle_path!(...)` (commit new path)
- Lines 174-175: `remove_bundle_path!(...)` then `add_bundle_path!(...)` (local rollback)

Each must accept and forward the optional `snapshot` kwarg.

- [ ] **Step 2: Modify the signature and forward the kwarg**

Replace the function body (lines 131-177) with:
```julia
function _try_reinsert_bundle!(
    sol::Solution{C},
    instance::Instance,
    bundle_idx::Int,
    mode_selector::AbstractModeSelector;
    packing::Symbol=:ffd_union,
    snapshot::Union{Nothing,Snapshot{C}}=nothing,
) where {C}
    isempty(sol.bundle_paths[bundle_idx]) && return 0.0
    ttg = instance.travel_time_graph

    old_path = copy(sol.bundle_paths[bundle_idx])
    cost_removed = remove_bundle_path!(sol, instance, bundle_idx; snapshot)
    update_bundle_cost_matrix!(sol, instance, bundle_idx, mode_selector; packing)
    origin = ttg.origin_codes[bundle_idx]
    dest = ttg.destination_codes[bundle_idx]
    res = Graphs.dijkstra_shortest_paths(ttg.graph, origin, ttg.cost_matrix)
    new_path = Graphs.enumerate_paths(res, dest)

    if isempty(new_path)
        add_bundle_path!(
            sol, instance, bundle_idx, old_path; mode_selector, packing, snapshot,
        )
        return 0.0
    end

    cost_added = add_bundle_path!(
        sol, instance, bundle_idx, new_path; mode_selector, packing, snapshot,
    )
    net_delta = cost_added + cost_removed
    if net_delta < -1e-6
        return -net_delta
    end

    if new_path == old_path
        return 0.0
    end

    remove_bundle_path!(sol, instance, bundle_idx; snapshot)
    add_bundle_path!(
        sol, instance, bundle_idx, old_path; mode_selector, packing, snapshot,
    )
    return 0.0
end
```

- [ ] **Step 3: Run existing tests**

Run:
```bash
julia --project=scripts -e '
include("test/Inbound.jl"); using .Inbound
include("test/test_local_search.jl")
include("test/test_two_node_consolidation.jl")
include("test/test_insertion.jl")
'
```
Expected: no failures.

- [ ] **Step 4: Commit**

```bash
git add src/algorithms/local_search.jl
git commit -m "feat: forward optional snapshot through _try_reinsert_bundle!"
```

### Task 1.4: Use snapshot for fast revert in `two_node_common_incremental!`

**Files:**
- Modify: `src/algorithms/two_node_consolidation.jl:172-236`.

- [ ] **Step 1: Write a regression test pinning exact-revert semantics**

Append to `test/test_snapshot_revert.jl`:
```julia
@testset "two_node_common_incremental! revert restores exact state" begin
    # Run two-node on several (src, dst) pairs. For each call that returns
    # delta == 0.0 (revert), the live state must compare equal to the
    # pre-state via cost(sol) and a field-level walk over assignments.
    # Mutable-struct `==` defaults to `===` in Julia, so direct Dict equality
    # is unreliable — we compare cost + path equality + per-assignment field
    # check explicitly.
    sol, instance = _mk_sol_from_inbound("small")
    ttg = instance.travel_time_graph
    src_codes, dst_codes = TPO.compute_candidate_nodes(ttg)
    pairs = collect(Iterators.take(
        ((s, d) for s in src_codes, d in dst_codes if s != d),
        20,
    ))

    function _snapshot_field_state(sol)
        d = Dict{Tuple{Int,Int},NamedTuple}()
        for (e, a) in sol.assignments
            d[e] = if a isa TPO.SingleAssignment
                (kind=:single,
                 commodities=copy(a.commodities),
                 bin_count=length(a.bins),
                 cost=a.cost,
                 sorted=a.sorted)
            else
                (kind=:multi, n_modes=length(a.per_mode),
                 costs=Tuple(s.cost for s in a.per_mode))
            end
        end
        return d
    end

    n_reverts = 0
    for (src, dst) in pairs
        pre_paths = deepcopy(sol.bundle_paths)
        pre_field_state = _snapshot_field_state(sol)
        pre_cost = TPO.cost(sol)

        delta = TPO.two_node_common_incremental!(
            sol, instance, src, dst; packing=:ffd_union, refine=true,
        )

        if delta == 0.0
            n_reverts += 1
            @test sol.bundle_paths == pre_paths
            @test isapprox(TPO.cost(sol), pre_cost; rtol=1e-10)
            post_field_state = _snapshot_field_state(sol)
            @test keys(post_field_state) == keys(pre_field_state)
            for e in keys(pre_field_state)
                @test post_field_state[e] == pre_field_state[e]
            end
        else
            @test TPO.cost(sol) < pre_cost - 1e-6
        end
    end
    @test n_reverts >= 1  # at least one revert must have happened
end
```

Run: `julia --project=scripts test/test_snapshot_revert.jl`
Expected: the new testset *may* pass even before the change (the existing revert code does work; it's just slow). If it passes, the assertion is pinning behavior — proceed. If it fails (very unlikely), debug first.

- [ ] **Step 2: Replace the body of `two_node_common_incremental!`**

Edit `src/algorithms/two_node_consolidation.jl`. Replace the function (lines 172-236) with:
```julia
function two_node_common_incremental!(
    sol::Solution{C},
    instance::Instance,
    src::Int,
    dst::Int;
    mode_selector::AbstractModeSelector=CheapestMode(),
    cost_threshold::Real=0.0,
    refine::Bool=true,
    packing::Symbol=:ffd_union,
) where {C}
    lifted_idxs = bundles_through_arc(sol, src, dst)
    isempty(lifted_idxs) && return 0.0

    if cost_threshold > 0
        est_saving = sum(
            bundle_estimated_removal_cost(sol, instance, i) for i in lifted_idxs; init=0.0
        )
        est_saving <= cost_threshold && return 0.0
    end

    old_paths = [copy(sol.bundle_paths[i]) for i in lifted_idxs]
    snapshot = Snapshot{C}()

    cost_removed = 0.0
    for i in lifted_idxs
        cost_removed += remove_bundle_path!(sol, instance, i; snapshot)
    end

    virtual_bundle, virtual_arcs = merge_bundles(instance, lifted_idxs)
    update_bundle_cost_matrix!(
        sol, instance, virtual_bundle, virtual_arcs, mode_selector; packing
    )
    ttg = instance.travel_time_graph
    res = Graphs.dijkstra_shortest_paths(ttg.graph, src, ttg.cost_matrix)
    new_sub_path = Graphs.enumerate_paths(res, dst)

    if isempty(new_sub_path)
        # Fast revert: restore all assignments + bundle_paths to original.
        restore_from_snapshot!(sol, snapshot)
        for (k, i) in enumerate(lifted_idxs)
            sol.bundle_paths[i] = old_paths[k]
        end
        return 0.0
    end

    cost_added = 0.0
    for (k, i) in enumerate(lifted_idxs)
        new_path = splice_path(old_paths[k], src, dst, new_sub_path)
        cost_added += add_bundle_path!(
            sol, instance, i, new_path; mode_selector, packing, snapshot,
        )
    end

    refine_saved = 0.0
    if refine
        for i in Random.shuffle(lifted_idxs)
            refine_saved += _try_reinsert_bundle!(
                sol, instance, i, mode_selector; packing, snapshot,
            )
        end
    end

    # Net cost change = forward deltas - refine saving. Accept iff net < -ε.
    net_delta = cost_removed + cost_added - refine_saved
    if net_delta < -1e-6
        return -net_delta
    end
    # Fast revert.
    restore_from_snapshot!(sol, snapshot)
    for (k, i) in enumerate(lifted_idxs)
        sol.bundle_paths[i] = old_paths[k]
    end
    return 0.0
end
```

Note: the function previously called `cost(sol)` twice (lines 193 and 226) to compute the accept decision. We now track `net_delta` incrementally — this is Phase 2's optimization combined with Phase 1's snapshot. Both go in together because (a) snapshot restores the exact pre-move state on reject, so we don't need `cost(sol)` to verify, and (b) the forward deltas are already returned by the primitives.

- [ ] **Step 3: Run the snapshot/revert tests**

Run: `julia --project=scripts test/test_snapshot_revert.jl`
Expected: all testsets including the exact-revert one pass.

- [ ] **Step 4: Run the cross-package comparison test**

Run:
```bash
julia --project=scripts -e '
include("test/Inbound.jl"); using .Inbound
include("test/test_compare_to_shipper.jl")
'
```
Expected: same pass count as before (the cross-package tolerances are wide enough that snapshot-vs-redo revert shouldn't shift any assertion).

- [ ] **Step 5: Run two-node, LS, and feasibility tests**

Run:
```bash
julia --project=scripts -e '
include("test/Inbound.jl"); using .Inbound
include("test/test_two_node_consolidation.jl")
include("test/test_local_search.jl")
include("test/test_frozen_packing.jl")
'
```
Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add src/algorithms/two_node_consolidation.jl test/test_snapshot_revert.jl
git commit -m "perf: snapshot-based fast revert in two_node_common_incremental!"
```

### Task 1.5: Benchmark and measure

**Files:**
- Use: `scripts/benchmark/run_comparison.jl`, `scripts/benchmark/ls_multirun.jl`.

- [ ] **Step 1: Run the full TPO/STP comparison**

Run:
```bash
rm scripts/benchmark/results/comparison.csv scripts/benchmark/results/comparison.md
julia --project=scripts scripts/benchmark/run_comparison.jl 2>&1 \
  | tee scripts/benchmark/results/phase1.log
```

Expected: per-instance LS iter/s improves by 1.2-1.5x over the Phase 0 baseline. The improvement scales with the share of two-node iters whose move is rejected (most of them at non-trivial sizes).

- [ ] **Step 2: Run the multi-run median benchmark**

Run:
```bash
INSTANCE=large N_RUNS=4 LS_BUDGET=30 julia --project=scripts \
  scripts/benchmark/ls_multirun.jl 2>&1 \
  | tee scripts/benchmark/results/phase1_large.log
```

Expected: median iter/s on large at `packing=:ffd_union` ≥ 1.4x the Phase 0 number.

- [ ] **Step 3: Re-profile to see the new bottleneck shape**

Run:
```bash
PROFILE_INSTANCE=large PROFILE_BUDGET=30 julia --project=scripts \
  scripts/benchmark/profile_ls_frozen.jl 2>&1 \
  | tee scripts/benchmark/results/ls_profile_phase1.txt
```

Inspect the new top consumers. The `revert` bucket (line 231 frame, now line numbers shifted) should be ~0% of LS samples. The new top bucket is likely the cost matrix update or `_remove_commodities`.

- [ ] **Step 4: Commit results**

```bash
git add scripts/benchmark/results/
git commit -m "bench: Phase 1 (snapshot revert) results"
```

---

## Phase 2 — Stack-allocate the linear drain mask

This is a small micro-optimization, ~2-5% expected. Worth doing because it's localized and fast to verify.

### Task 2.1: Rewrite `_drain_first_matches_linear!` to use a stack-allocated mask

**Files:**
- Modify: `src/solution/solution.jl` — `_drain_first_matches_linear!` (function defined after `_drain_first_matches!`).

- [ ] **Step 1: Read the current implementation**

Read the function (search for `function _drain_first_matches_linear!`). It currently uses `matched = falses(n_to_remove)` (BitVector, allocates) and `dropped = C[]` (Vector, allocates and grows).

- [ ] **Step 2: Modify to use a UInt8 bitmask and pre-sized `dropped`**

Replace the function body with:
```julia
function _drain_first_matches_linear!(
    pool::Vector{C}, to_remove::Vector{C}
) where {C<:LightCommodity}
    n_to_remove = length(to_remove)
    # The adaptive dispatcher above caps `n_to_remove ≤ 8`, so a UInt8 bitmask
    # has enough bits to track per-slot match state without allocation.
    @assert n_to_remove <= 8
    matched::UInt8 = 0x00
    n_pool = length(pool)
    # Worst case: every pool element matches; pre-size dropped to that bound
    # (n_to_remove) and shrink at the end. Avoids per-push! reallocation.
    dropped = Vector{C}(undef, n_to_remove)
    n_dropped = 0
    write_idx = 0
    @inbounds for read_idx in 1:n_pool
        c = pool[read_idx]
        match_idx = 0
        for i in 1:n_to_remove
            if (matched >> (i - 1)) & 0x01 == 0x00 && to_remove[i] == c
                match_idx = i
                break
            end
        end
        if match_idx > 0
            matched |= UInt8(1) << (match_idx - 1)
            n_dropped += 1
            dropped[n_dropped] = c
        else
            write_idx += 1
            pool[write_idx] = c
        end
    end
    resize!(pool, write_idx)
    resize!(dropped, n_dropped)

    # Compact to_remove in place, keeping unmatched entries in original order.
    write_idx = 0
    @inbounds for i in 1:n_to_remove
        if (matched >> (i - 1)) & 0x01 == 0x00
            write_idx += 1
            to_remove[write_idx] = to_remove[i]
        end
    end
    resize!(to_remove, write_idx)

    return dropped
end
```

- [ ] **Step 3: Run the contract tests**

Run: `julia --project=scripts test/test_drain_first_matches.jl`
Expected: 33/33 tests pass.

- [ ] **Step 4: Microbench against captured inputs**

Run: `julia --project=scripts scripts/benchmark/microbench_drain.jl`
Expected: per-bucket speedup on `to_remove ∈ [1, 5)` improves slightly over the BitVector version (no `Bool[]` allocation).

- [ ] **Step 5: Commit**

```bash
git add src/solution/solution.jl
git commit -m "perf: UInt8 bitmask in _drain_first_matches_linear! (no per-call alloc)"
```

### Task 2.2: Benchmark Phase 2

**Files:**
- Use: `scripts/benchmark/run_comparison.jl`.

- [ ] **Step 1: Re-run the comparison**

Run:
```bash
rm scripts/benchmark/results/comparison.csv scripts/benchmark/results/comparison.md
julia --project=scripts scripts/benchmark/run_comparison.jl 2>&1 \
  | tee scripts/benchmark/results/phase2.log
```

Expected: LS iter/s improves a few % on top of Phase 1. If the change is below measurement noise (< 3%), accept the result as a correctness/clarity win and move on.

- [ ] **Step 2: Commit results**

```bash
git add scripts/benchmark/results/
git commit -m "bench: Phase 2 (drain bitmask) results"
```

---

## Phase 3 — Verify and document

### Task 3.1: Re-profile and decide whether further work is justified

**Files:**
- Use: `scripts/benchmark/profile_ls_frozen.jl`.

- [ ] **Step 1: Re-profile on large**

Run:
```bash
PROFILE_INSTANCE=large PROFILE_BUDGET=30 julia --project=scripts \
  scripts/benchmark/profile_ls_frozen.jl 2>&1 \
  | tee scripts/benchmark/results/ls_profile_phase3.txt
```

- [ ] **Step 2: Decision point — write a one-paragraph summary**

Update `scripts/benchmark/results/phase_targets.md` to record the post-Phase-2 distribution. Compare to Phase 0. Decide:

- If the gap to STP is > 3x on `large`: continue with one of the deferred items (refine-loop trimming, dense bin storage). Plan separately.
- If the gap to STP is ≤ 2.5x on `large`: stop here. Further wins require structural refactor of `slot.commodities`/`slot.bins`.

Document the decision and the numbers in the summary.

- [ ] **Step 3: Commit**

```bash
git add scripts/benchmark/results/
git commit -m "bench: Phase 3 final profile and gap decision"
```

### Task 3.2: Update the cross-package summary

**Files:**
- Use: existing CLAUDE.md (root of repository) and `scripts/benchmark/results/comparison.md`.

- [ ] **Step 1: Update CLAUDE.md performance section**

If `CLAUDE.md` doesn't already have a performance section, append one citing the comparison.md file and the headline numbers (gap to STP, cost ratio). Keep it short (no full tables). One sentence per phase.

If it already has one, refresh the numbers.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: refresh perf section after snapshot/incremental work"
```

---

## Risks and rollback

- **Snapshot allocation cost on accepted moves.** Every two-node move pays for `deepcopy` of touched assignments, even when it accepts. Phase 1.5's re-profile must show that this overhead is smaller than the savings on rejected moves. If not (i.e., LS iter/s does not improve net), revert Task 1.4 with `git revert`, leaving the kwargs in place but the two-node function unchanged. The kwargs are still useful for tests and future work.

- **Drift between `cost(sol)` and incremental `net_delta` under `:frozen`.** With snapshot-based revert, we restore the exact pre-move state on reject, so any drift only affects accepted moves where it's the "real" cost change. Acceptable. Document in the function docstring that the accept decision uses incremental deltas and is therefore consistent with the snapshot revert.

- **UInt8 mask assumes `n_to_remove ≤ 8`.** Enforced by the dispatcher in `_drain_first_matches!`. The `@assert` documents the invariant. If a future change lifts the threshold above 8, replace `UInt8` with `UInt32` and the assertion with `n_to_remove ≤ 32`.

## Out of scope

- Parallelism (`OhMyThreads.@tasks` on the bundle_arcs loop in `update_bundle_cost_matrix!`). Plan separately if pursued — orthogonal multiplier of ~3x on a 4-core box.
- Structural decoupling of `slot.commodities` from `slot.bins` for `:frozen` mode. Bigger refactor; separate plan.
- Refine-loop trimming. Quality-sensitive; only attempt if Phase 3 profile still shows refine as the dominant bucket.
- Switching LS default to `:frozen`. Strategic, not a perf fix.
