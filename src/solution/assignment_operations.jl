"""
$TYPEDSIGNATURES

Ensure `slot.commodities` is in descending order by `.size`, sorting in place if not already.
"""
function _ensure_sorted!(slot::SingleAssignment)
    slot.sorted && return slot
    sort!(slot.commodities; by=c -> c.size, rev=true)
    slot.sorted = true
    return slot
end

"""
$TYPEDSIGNATURES

Append `new_commodities` into `slot.commodities` while preserving the
descending-by-size invariant. `new_commodities` is assumed to already be in
descending order.
"""
function _merge_sorted_into_slot!(
    slot::SingleAssignment{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    isempty(new_commodities) && return slot
    slot.total_size += sum(c.size for c in new_commodities; init=0.0)
    # If the existing slot is unsorted, we can't guarantee the invariant, so just append.
    if !slot.sorted
        append!(slot.commodities, new_commodities)
        return slot
    end
    # Else
    n = length(slot.commodities)
    k = length(new_commodities)
    if n == 0
        append!(slot.commodities, new_commodities)
        return slot
    end
    # In-place two-pointer merge from the back. Writing slot[w] only ever
    # overwrites a slot position already past the read pointer `i`, so the
    # merge is safe in place. `w >= i + (k - new_picks)` holds throughout.
    resize!(slot.commodities, n + k)
    i = n
    j = k
    w = n + k
    @inbounds while i >= 1 && j >= 1
        a = slot.commodities[i]
        b = new_commodities[j]
        if a.size <= b.size
            slot.commodities[w] = a
            i -= 1
        else
            slot.commodities[w] = b
            j -= 1
        end
        w -= 1
    end
    @inbounds while j >= 1
        slot.commodities[w] = new_commodities[j]
        j -= 1
        w -= 1
    end
    # Any remaining slot.commodities[1..i] are already in their correct positions.
    return slot
end

@inline function _evaluate_with_total_size(
    arc_f::AbstractArcCostFunction,
    commodities::Vector{<:LightCommodity},
    ::Float64;
    presorted::Bool=false,
)
    return evaluate(arc_f, commodities; presorted)
end

@inline function _evaluate_with_total_size(
    arc_f::LinearArcCost,
    ::Vector{<:LightCommodity},
    total_size::Float64;
    presorted::Bool=false,
)
    return arc_f.cost_per_unit_size * total_size
end

@inline _sum_evaluate_with_total_size(
    ::Tuple{}, ::Vector{C}, ::Float64
) where {C<:LightCommodity} = 0.0
@inline function _sum_evaluate_with_total_size(
    terms::Tuple, comms::Vector{C}, total_size::Float64
) where {C<:LightCommodity}
    return _evaluate_with_total_size(first(terms), comms, total_size; presorted=true) +
           _sum_evaluate_with_total_size(Base.tail(terms), comms, total_size)
end

function _update_single_assignment_cost!(
    slot::SingleAssignment, arc_cost::AbstractArcCostFunction
)
    _ensure_sorted!(slot)
    slot.cost = _evaluate_with_total_size(
        arc_cost, slot.commodities, slot.total_size; presorted=true
    )
    return nothing
end

# Cost update helpers for `SingleAssignment` slots.
function _update_single_assignment_cost!(
    slot::SingleAssignment, arc_cost::BinPackingArcCost
)
    _ensure_sorted!(slot)
    slot.bins = compute_bin_assignments(arc_cost, slot.commodities; presorted=true)
    slot.cost = arc_cost.cost_per_bin * length(slot.bins)
    slot.bins_dirty = false
    return nothing
end

function _update_single_assignment_cost!(slot::SingleAssignment, arc_cost::SumArcCost)
    _ensure_sorted!(slot)
    # When SumArcCost wraps a BinPackingArcCost term, refresh slot.bins so the
    # cached bin count stays consistent with slot.commodities (read by
    # incremental_cost! to skip the FFD-on-existing pass).
    bp = _try_find_bin_packing(arc_cost)
    if bp !== nothing
        slot.bins = compute_bin_assignments(bp, slot.commodities; presorted=true)
    end
    slot.cost = _sum_evaluate_with_total_size(
        arc_cost.terms, slot.commodities, slot.total_size
    )
    slot.bins_dirty = false
    return nothing
end

# Removal-only cost update: recompute `slot.cost` without materializing bins.
# Matches STP's "does not refill bins" semantics. The `slot.bins` vector becomes
# stale, and `bins_dirty` is set so downstream code can fall back to non-frozen
# cost estimation. The next `_update_single_assignment_cost!` (on add) will
# recompute bins and clear the flag.
function _update_cost_skip_bins!(slot::SingleAssignment, arc_cost::AbstractArcCostFunction)
    _ensure_sorted!(slot)
    slot.cost = _evaluate_with_total_size(
        arc_cost, slot.commodities, slot.total_size; presorted=true
    )
    return nothing
end

function _update_cost_skip_bins!(slot::SingleAssignment, arc_cost::BinPackingArcCost)
    _ensure_sorted!(slot)
    slot.cost =
        arc_cost.cost_per_bin *
        tentative_bin_count(arc_cost, slot.commodities; presorted=true)
    slot.bins_dirty = true
    return nothing
end

function _update_cost_skip_bins!(slot::SingleAssignment, arc_cost::SumArcCost)
    _ensure_sorted!(slot)
    slot.cost = _sum_evaluate_with_total_size(
        arc_cost.terms, slot.commodities, slot.total_size
    )
    slot.bins_dirty = true
    return nothing
end

"""
$TYPEDSIGNATURES

Frozen-bin commit for a single-mode slot.  Instead of re-packing, this adds only
`new_comms` to the cached `slot.bins` via first-fit, keeping the existing bins frozen.
"""
function _frozen_commit_single_assignment!(
    slot::SingleAssignment{C}, arc_cost::AbstractArcCostFunction, ::Vector{C}
) where {C}
    return _update_single_assignment_cost!(slot, arc_cost)
end

function _frozen_commit_single_assignment!(
    slot::SingleAssignment{C}, arc_cost::BinPackingArcCost, new_comms::Vector{C}
) where {C}
    if slot.bins_dirty
        return _update_single_assignment_cost!(slot, arc_cost)
    end
    frozen_first_fit_add!(slot.bins, Float64(arc_cost.bin_capacity), new_comms)
    slot.cost = arc_cost.cost_per_bin * length(slot.bins)
    return nothing
end

@inline function _frozen_term_commit!(
    slot::SingleAssignment, term::BinPackingArcCost, new_comms::Vector
)
    if slot.bins_dirty
        slot.bins = compute_bin_assignments(term, slot.commodities; presorted=true)
        slot.bins_dirty = false
    else
        frozen_first_fit_add!(slot.bins, Float64(term.bin_capacity), new_comms)
    end
    return term.cost_per_bin * length(slot.bins)
end
@inline _frozen_term_commit!(
    slot::SingleAssignment, term::AbstractArcCostFunction, ::Vector
) = _evaluate_with_total_size(term, slot.commodities, slot.total_size)

@inline _sum_frozen_commit!(::SingleAssignment, ::Tuple{}, ::Vector) = 0.0
@inline _sum_frozen_commit!(slot::SingleAssignment, terms::Tuple, new_comms::Vector) =
    _frozen_term_commit!(slot, first(terms), new_comms) +
    _sum_frozen_commit!(slot, Base.tail(terms), new_comms)

function _frozen_commit_single_assignment!(
    slot::SingleAssignment{C}, arc_cost::SumArcCost, new_comms::Vector{C}
) where {C}
    slot.cost = _sum_frozen_commit!(slot, arc_cost.terms, new_comms)
    return nothing
end

"""
$TYPEDSIGNATURES

Partition `new_comms` across the modes of `arc` in cheapest-first order, filling
each mode up to its remaining capacity before moving to the next.

Returns `(partition, overflow)` where `partition[i]` is the subset of
`new_comms` assigned to `arc.modes[i]`, and `overflow` is `true` if the combined
remaining capacity across all modes is insufficient to absorb `new_comms`.
"""
function _fill_then_spill_partition(
    arc::MultiModalArc,
    existing_per_mode::Vector{Vector{C}},
    new_comms::Vector{C};
    existing_total_sizes::Vector{Float64}=Float64[],
) where {C<:LightCommodity}
    mode_costs = [
        incremental_cost(arc.modes[i].cost, existing_per_mode[i], new_comms) for
        i in eachindex(arc.modes)
    ]
    sorted_indices = sortperm(mode_costs)

    per_mode_new = [C[] for _ in eachindex(arc.modes)]
    remaining = copy(new_comms)
    have_cached_sizes = !isempty(existing_total_sizes)

    for mode_idx in sorted_indices
        isempty(remaining) && break
        mode = arc.modes[mode_idx]
        existing_size = if have_cached_sizes
            existing_total_sizes[mode_idx]
        else
            sum(c.size for c in existing_per_mode[mode_idx]; init=0.0)
        end
        cap_left = Float64(mode.capacity) - existing_size

        placed = C[]
        still_remaining = C[]
        placed_size = 0.0

        for c in remaining
            if placed_size + c.size <= cap_left + EPS
                push!(placed, c)
                placed_size += c.size
            else
                push!(still_remaining, c)
            end
        end

        per_mode_new[mode_idx] = placed
        remaining = still_remaining
    end

    overflow = !isempty(remaining)
    return per_mode_new, overflow
end

"""
$TYPEDSIGNATURES

Add `new_commodities` to the edge assignment for `edge` following the `FillThenSpillMode` logic.
"""
function _fill_then_spill_assign!(
    edge::Tuple{Int,Int},
    arc::MultiModalArc,
    assignment::MultiAssignment{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    existing_per_mode = [slot.commodities for slot in assignment.per_mode]
    cached_sizes = [slot.total_size for slot in assignment.per_mode]
    partition, overflow = _fill_then_spill_partition(
        arc, existing_per_mode, new_commodities; existing_total_sizes=cached_sizes
    )
    if overflow
        throw(
            ArgumentError(
                "No combination of modes on edge $(edge) has enough capacity for the new commodities under FillThenSpillMode",
            ),
        )
    end
    cost_delta = 0.0
    for (i, placed) in enumerate(partition)
        isempty(placed) && continue
        slot = assignment.per_mode[i]
        before = slot.cost
        # `placed` is a subset of the order's commodities, which are sorted
        # desc at construction. The merge preserves slot.sorted=true.
        _merge_sorted_into_slot!(slot, placed)
        _update_single_assignment_cost!(slot, arc.modes[i].cost)
        cost_delta += slot.cost - before
    end
    return cost_delta
end

function _add_order_to_assignment!(
    assignments::Dict{Tuple{Int,Int},<:AbstractArcAssignment{C}},
    edge::Tuple{Int,Int},
    arc::NetworkArc,
    new_commodities::Vector{C},
    ::AbstractModeSelector;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    assignment = get!(assignments, edge) do
        SingleAssignment{C}()
    end::SingleAssignment{C}
    before = assignment.cost
    # new_commodities is sorted desc by the Order invariant. The merge
    # preserves assignment.sorted=true so the next remove can skip its
    # _ensure_sorted! sort.
    _merge_sorted_into_slot!(assignment, new_commodities)
    if packing === :frozen
        _frozen_commit_single_assignment!(assignment, arc.cost, new_commodities)
    else
        _update_single_assignment_cost!(assignment, arc.cost)
    end
    return assignment.cost - before
end

function _add_order_to_assignment!(
    assignments::Dict{Tuple{Int,Int},<:AbstractArcAssignment{C}},
    edge::Tuple{Int,Int},
    arc::MultiModalArc,
    new_commodities::Vector{C},
    ::CheapestMode;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    assignment = get!(assignments, edge) do
        MultiAssignment{C}(length(arc.modes))
    end::MultiAssignment{C}
    mode_costs = [
        if _mode_has_capacity(
            arc.modes[i], assignment.per_mode[i].total_size, new_commodities
        )
            _commit_mode_incremental(
                arc.modes[i].cost, assignment.per_mode[i], new_commodities, packing
            )
        else
            Inf
        end for i in eachindex(arc.modes)
    ]
    best_mode_idx = argmin(mode_costs)
    if isinf(mode_costs[best_mode_idx])
        throw(
            ArgumentError(
                "No mode on edge $(edge) has enough capacity for the new commodities under CheapestMode",
            ),
        )
    end
    slot = assignment.per_mode[best_mode_idx]
    before = slot.cost
    # new_commodities is sorted desc by the Order invariant. Merge preserves
    # slot.sorted=true so the next remove can skip its _ensure_sorted! sort.
    _merge_sorted_into_slot!(slot, new_commodities)
    if packing === :frozen
        _frozen_commit_single_assignment!(
            slot, arc.modes[best_mode_idx].cost, new_commodities
        )
    else
        _update_single_assignment_cost!(slot, arc.modes[best_mode_idx].cost)
    end
    return slot.cost - before
end

"""
$TYPEDSIGNATURES

Per-mode incremental cost used by the `CheapestMode` commit to pick the mode.
Under `:frozen` it scores against the slot's cached frozen bins (matching the
greedy cost matrix), otherwise it uses the standard `incremental_cost`.
"""
function _commit_mode_incremental(
    mode_cost::AbstractArcCostFunction,
    slot::SingleAssignment{C},
    new_commodities::Vector{C},
    packing::Symbol,
) where {C<:LightCommodity}
    if packing === :frozen
        return _frozen_edge_incremental_cost(
            BinPackingBuffer(), mode_cost, slot, new_commodities
        )
    end
    return incremental_cost(mode_cost, slot.commodities, new_commodities)
end

function _add_order_to_assignment!(
    assignments::Dict{Tuple{Int,Int},<:AbstractArcAssignment{C}},
    edge::Tuple{Int,Int},
    arc::MultiModalArc,
    new_commodities::Vector{C},
    ::FillThenSpillMode;
    packing::Symbol=:frozen,
) where {C<:LightCommodity}
    # FillThenSpillMode always uses ffd_union semantics (re-packs each affected
    # mode), matching its `_edge_incremental_cost`. `packing` is accepted for
    # signature uniformity but does not switch to frozen here.
    assignment = get!(assignments, edge) do
        MultiAssignment{C}(length(arc.modes))
    end::MultiAssignment{C}
    return _fill_then_spill_assign!(edge, arc, assignment, new_commodities)
end

function _mode_has_capacity(
    mode::NetworkArc, existing::Vector{C}, new_comms::Vector{C}
) where {C<:LightCommodity}
    mode.capacity == typemax(Int) && return true
    existing_size = sum(c.size for c in existing; init=0.0)
    new_size = sum(c.size for c in new_comms; init=0.0)
    return existing_size + new_size <= mode.capacity + EPS
end

function _mode_has_capacity(
    mode::NetworkArc, existing_total_size::Float64, new_comms::Vector{<:LightCommodity}
)
    mode.capacity == typemax(Int) && return true
    new_size = sum(c.size for c in new_comms; init=0.0)
    return existing_total_size + new_size <= mode.capacity + EPS
end

function _remove_commodities_from_assignment!(
    assignment::SingleAssignment{C}, arc::NetworkArc, removed_comms::Vector{C}
) where {C<:LightCommodity}
    before = assignment.cost
    n_removed = _remove_all_from_pool!(assignment.commodities, removed_comms)
    if n_removed != length(removed_comms)
        n_missing = length(removed_comms) - n_removed
        throw(
            ArgumentError(
                "remove_bundle_path!: $(n_missing) commodities not found in single-mode assignment",
            ),
        )
    end
    assignment.total_size -= sum(c.size for c in removed_comms; init=0.0)
    _update_cost_skip_bins!(assignment, arc.cost)
    return assignment.cost - before
end

function _remove_commodities_from_assignment!(
    assignment::MultiAssignment{C}, arc::MultiModalArc, removed_comms::Vector{C}
) where {C<:LightCommodity}
    before = sum(slot.cost for slot in assignment.per_mode; init=0.0)
    remaining = copy(removed_comms)
    for (i, slot) in enumerate(assignment.per_mode)
        isempty(remaining) && break
        dropped = _drain_first_matches!(slot.commodities, remaining)
        if !isempty(dropped)
            slot.total_size -= sum(c.size for c in dropped; init=0.0)
            _update_cost_skip_bins!(slot, arc.modes[i].cost)
        end
    end
    if !isempty(remaining)
        throw(
            ArgumentError(
                "remove_bundle_path!: $(length(remaining)) commodities not found across modes for this edge",
            ),
        )
    end
    after = sum(slot.cost for slot in assignment.per_mode; init=0.0)
    return after - before
end

"""
$TYPEDSIGNATURES

Remove from `pool` every element that `==`-matches an element in `to_remove`,
without allocating intermediate collections. Unlike `_drain_first_matches!`,
does not mutate `to_remove` and does not return dropped items. Returns the
number of matches found.

Used by the SingleAssignment removal path where all commodities are expected
to be present (the caller checks `n_removed == length(to_remove)`).
"""
function _remove_all_from_pool!(
    pool::Vector{C}, to_remove::AbstractVector{C}
) where {C<:LightCommodity}
    n_to_remove = length(to_remove)
    n_to_remove == 0 && return 0
    n_pool = length(pool)
    if n_to_remove <= 8
        return _remove_all_from_pool_linear!(pool, to_remove)
    end
    return _remove_all_from_pool_dict!(pool, to_remove)
end

function _remove_all_from_pool_linear!(
    pool::Vector{C}, to_remove::AbstractVector{C}
) where {C<:LightCommodity}
    n_to_remove = length(to_remove)
    matched = falses(n_to_remove)
    n_matched = 0
    n_pool = length(pool)
    write_idx = 0
    @inbounds for read_idx in 1:n_pool
        c = pool[read_idx]
        found = false
        if n_matched < n_to_remove
            for i in 1:n_to_remove
                if !matched[i] && to_remove[i] == c
                    matched[i] = true
                    n_matched += 1
                    found = true
                    break
                end
            end
        end
        if !found
            write_idx += 1
            pool[write_idx] = c
        end
    end
    resize!(pool, write_idx)
    return n_matched
end

function _remove_all_from_pool_dict!(
    pool::Vector{C}, to_remove::AbstractVector{C}
) where {C<:LightCommodity}
    counts = Dict{C,Int}()
    sizehint!(counts, length(to_remove))
    for c in to_remove
        counts[c] = get(counts, c, 0) + 1
    end
    n_pool = length(pool)
    write_idx = 0
    n_matched = 0
    @inbounds for read_idx in 1:n_pool
        c = pool[read_idx]
        ct = get(counts, c, 0)
        if ct > 0
            counts[c] = ct - 1
            n_matched += 1
        else
            write_idx += 1
            pool[write_idx] = c
        end
    end
    resize!(pool, write_idx)
    return n_matched
end

"""
$TYPEDSIGNATURES

For each item in `to_remove`, drop its first `==`-matching occurrence in `pool`
(if any). Items that find a match are removed from both `pool` and `to_remove`,
so that on return `to_remove` contains exactly the items that were not matched
in `pool`. Returns the vector of items that were actually dropped.

This dual-mutation contract is convenient when scanning a queue of items across
several pools (for example, across the modes of a `MultiAssignment`): pass the
same `to_remove` vector to successive calls and stop when it is empty.

# Adaptive strategy

Two implementations are dispatched on `length(to_remove)`:

- **Linear-scan** for `length(to_remove) ≤ 8`. No `Dict` allocation; for each
  pool element, scan `to_remove` for the first unmatched equal entry.
- **Dict-based multiset** for larger `to_remove`. The dictionary amortizes
  pool walks of `O(|pool|)` look-ups regardless of `|to_remove|`.

The 8-element cutoff was chosen from a captured-input microbench
(`scripts/benchmark/microbench_drain.jl`): on LS-realistic inputs, linear wins
2.5x for `to_remove ≤ 5`, breaks even around 5-10, and loses 2-3x for
`to_remove ∈ [10, 32]`. The instrumented LS distribution puts ~57% of calls
under the threshold (median `to_remove = 3`).
"""
function _drain_first_matches!(
    pool::Vector{C}, to_remove::Vector{C}
) where {C<:LightCommodity}
    isempty(to_remove) && return C[]
    if length(to_remove) <= 8
        return _drain_first_matches_linear!(pool, to_remove)
    end
    return _drain_first_matches_dict!(pool, to_remove)
end

"""
$TYPEDSIGNATURES

Linear-scan implementation of `_drain_first_matches!`. Tracks which
`to_remove` indices have already been matched via a `BitVector`. For each pool
element, scans the unmatched indices in `to_remove` for the first `==`
match. Stable in pool order; preserves original order of unmatched entries in
`to_remove`. Used when `length(to_remove)` is small (the dominant case).
"""
function _drain_first_matches_linear!(
    pool::Vector{C}, to_remove::Vector{C}
) where {C<:LightCommodity}
    n_to_remove = length(to_remove)
    matched = falses(n_to_remove)
    n_pool = length(pool)
    write_idx = 0
    dropped = C[]
    @inbounds for read_idx in 1:n_pool
        c = pool[read_idx]
        match_idx = 0
        for i in 1:n_to_remove
            if !matched[i] && to_remove[i] == c
                match_idx = i
                break
            end
        end
        if match_idx > 0
            matched[match_idx] = true
            push!(dropped, c)
        else
            write_idx += 1
            pool[write_idx] = c
        end
    end
    resize!(pool, write_idx)

    # Compact to_remove in place, keeping unmatched entries in original order.
    write_idx = 0
    @inbounds for i in 1:n_to_remove
        if !matched[i]
            write_idx += 1
            to_remove[write_idx] = to_remove[i]
        end
    end
    resize!(to_remove, write_idx)

    return dropped
end

"""
$TYPEDSIGNATURES

Dict-based multiset implementation of `_drain_first_matches!`. Used when
`length(to_remove)` is large, where the `O(|pool|)` dictionary look-up cost
beats the linear scan's `O(|pool| × |to_remove|)`.
"""
function _drain_first_matches_dict!(
    pool::Vector{C}, to_remove::Vector{C}
) where {C<:LightCommodity}
    counts = Dict{C,Int}()
    for c in to_remove
        counts[c] = get(counts, c, 0) + 1
    end

    n_pool = length(pool)
    write_idx = 0
    dropped = C[]
    for read_idx in 1:n_pool
        c = pool[read_idx]
        ct = get(counts, c, 0)
        if ct > 0
            counts[c] = ct - 1
            push!(dropped, c)
        else
            write_idx += 1
            pool[write_idx] = c
        end
    end
    resize!(pool, write_idx)

    write_idx = 0
    for read_idx in 1:length(to_remove)
        c = to_remove[read_idx]
        ct = get(counts, c, 0)
        if ct > 0
            counts[c] = ct - 1
            write_idx += 1
            to_remove[write_idx] = c
        end
    end
    resize!(to_remove, write_idx)

    return dropped
end
