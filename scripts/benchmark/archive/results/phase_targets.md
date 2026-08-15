# Phase targets — measured on large packing=:frozen, 30s budget

Source: `scripts/benchmark/results/ls_profile_phase0.txt` (run 2026-05-29 after the adaptive-drain + merge-on-add commits).

**Iter/s observed:** 185.5 iter/s.
**Total LS samples (under `local_search!`):** 17,957 active samples.

## Sample distribution under `local_search!`

| Bucket | Samples | % of LS |
|---|---|---|
| `_run_two_node_step!` (line 323/416) | 11,537 | **64.3%** |
| `_run_reintro_step!` (line 321/392) | 6,419 | **35.7%** |

## Inside `two_node_common_incremental!` (11,537 samples)

| Site | Samples | % of LS |
|---|---|---|
| Function entry / merged-bundle cost matrix (line 172) | 2,464 | 13.7% |
| Lifted removals (line 196) | 1,393 | 7.8% |
| Add new spliced path (line 217) | 238 | 1.3% |
| **Refine loop `_try_reinsert_bundle!`** (line 222) | **5,114** | **28.5%** |
| **Revert path** (line 231) | **2,008** | **11.2%** |
| Revert inner remove (line 232) | 282 | 1.6% |

## Notable absent

- `cost(sol)` (lines 193 / 226 of two-node): below tree-profile mincount=300, i.e. < 1.7% of LS. Folding the two calls into incremental `net_delta` accumulation will save < 2% — kept as a structural-correctness change but not a perf priority.

## Buckets targeted by this plan

- **Phase 1 (snapshot-based fast revert)** targets the revert bucket: 11.2% of LS. With snapshot+restore (~free) vs current remove+add per lifted bundle, this bucket should drop to ~1% (just the restore loop + path overwrites). Expected LS iter/s gain: ~11% on `large :frozen` if the bucket is fully eliminated, less if the snapshot construction cost on accepted moves takes some of it back.
- **Phase 2 (drain bitmask)** targets per-call allocation of `_drain_first_matches_linear!` (1,334 samples = 7.4% in the tree, attributed via `_drain_first_matches_linear!` self-time line). Small but cheap. Expected gain: 2-3%.

## Buckets out of scope

- **Refine loop (28.5%)** — quality-sensitive. Trimming refined bundles is a separate plan if attempted.
- **Cost matrix update inside `_try_reinsert_bundle!`** (rolls up into the 28.5% refine bucket and the per-`_try_reinsert_bundle!` work inside it). Per-arc work itself is fundamental; structural fix is the slot.commodities/slot.bins decouple, a separate plan.
- **`_run_reintro_step!` (35.7%)** — same per-iter work as two-node's `_try_reinsert_bundle!`. Drain/merge fixes already applied; further wins require the same structural fixes as the refine bucket.
