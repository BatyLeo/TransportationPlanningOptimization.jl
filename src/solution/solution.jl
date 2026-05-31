"""
$TYPEDEF

A solution to the network design optimization problem.
It stores the chosen paths for each bundle in the `TravelTimeGraph` and precomputes
key metrics such as commodity distributions on arcs and individual arc costs.

# Fields
$TYPEDFIELDS
"""
struct Solution{C<:LightCommodity}
    "Paths for each bundle in the instance. `bundle_paths[i]` is a sequence of node codes in the `TravelTimeGraph` for the i-th bundle."
    bundle_paths::Vector{Vector{Int}}
    "Per-edge assignment payload, keyed by `(u_tsg_code, v_tsg_code)`. Values are `SingleAssignment{C}` for single-mode edges and `MultiAssignment{C}` for multi-modal edges. The 2-element union lets Julia apply union-splitting at all dispatch sites."
    assignments::Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}
end

function Base.show(io::IO, sol::Solution)
    nb_trucks = sum(_bin_count(a) for a in values(sol.assignments); init=0)
    return print(io, "Solution(num_trucks=$(nb_trucks), assignments=$(sol.assignments))")
end

_bin_count(a::SingleAssignment) = length(a.bins)
_bin_count(a::MultiAssignment) = sum(length(slot.bins) for slot in a.per_mode; init=0)

"""
    Solution(instance::Instance)

Initialize an empty solution for the given instance.
"""
function Solution(instance::Instance{Bundle{Order{IDA,I}}}) where {IDA,I}
    C = LightCommodity{IDA,I}
    return Solution{C}(
        [Int[] for _ in 1:bundle_count(instance)],
        Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}(),
    )
end

"""
$TYPEDSIGNATURES

Check if a solution is feasible for a given instance.
Feasibility requires:
1. Every bundle in the instance must have a corresponding path in the solution.
2. Every path must exist (each arc exists in the graph).
3. Every path must start at the bundle's designated entry node (`origin_codes`).
4. Every path must end at the bundle's designated exit node (`destination_codes`).
"""
function is_feasible(sol::Solution, instance::Instance; verbose::Bool=false)
    (; travel_time_graph, time_space_graph) = instance
    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        if isempty(path)
            verbose && @warn "Bundle $(bundle_idx) has an empty path."
            return false
        end

        bundle = instance.bundles[bundle_idx]

        # Check connectivity and forbidden constraints
        for i in 1:(length(path) - 1)
            u, v = path[i], path[i + 1]
            if !Graphs.has_edge(travel_time_graph.graph, u, v)
                verbose &&
                    @warn "Arc ($(u), $(v)) in bundle $(bundle_idx) path does not exist."
                return false
            end

            # Check forbidden nodes (intermediate nodes only, origin/destination already validated)
            u_label = MetaGraphsNext.label_for(travel_time_graph.graph, u)
            v_label = MetaGraphsNext.label_for(travel_time_graph.graph, v)
            u_node_id = u_label[1]
            v_node_id = v_label[1]

            # Check if intermediate nodes are forbidden (skip origin and destination)
            if i > 1 && u_node_id in bundle.forbidden_nodes
                verbose &&
                    @warn "Bundle $(bundle_idx) path uses forbidden node $(u_node_id) at position $(i)."
                return false
            end
            if i < length(path) - 1 && v_node_id in bundle.forbidden_nodes
                verbose &&
                    @warn "Bundle $(bundle_idx) path uses forbidden node $(v_node_id) at position $(i+1)."
                return false
            end

            # Check forbidden arcs
            if (u_node_id, v_node_id) in bundle.forbidden_arcs
                verbose &&
                    @warn "Bundle $(bundle_idx) path uses forbidden arc ($(u_node_id), $(v_node_id))."
                return false
            end
        end

        # Check start node: if it's exactly the expected code, accept immediately,
        # otherwise perform tolerant checks comparing spatial IDs and times.
        start_node_code = path[1]
        valid_origin = travel_time_graph.origin_codes[bundle_idx]
        if start_node_code != valid_origin
            start_label = MetaGraphsNext.label_for(travel_time_graph.graph, start_node_code)
            origin_label = MetaGraphsNext.label_for(travel_time_graph.graph, valid_origin)
            # Spatial must match
            if start_label[1] != origin_label[1]
                verbose &&
                    @warn "Bundle $(bundle_idx) starts at spatial node $(start_label[1]) instead of valid origin $(origin_label[1])."
                return false
            end
            # Time must be in a sensible range and respect semantics
            if is_date_arrival(travel_time_graph)
                # start τ must be <= origin τ (max duration)
                if start_label[2] > origin_label[2] || start_label[2] < 0
                    verbose &&
                        @warn "Bundle $(bundle_idx) starts at invalid time τ=$(start_label[2]) for arrival-mode origin (max τ=$(origin_label[2]))."
                    return false
                end
            else
                # elapsed-time: start τ must be >= origin τ (usually 0)
                if start_label[2] < origin_label[2] ||
                    start_label[2] > travel_time_graph.max_time_steps
                    verbose &&
                        @warn "Bundle $(bundle_idx) starts at invalid time τ=$(start_label[2]) for elapsed-mode origin (min τ=$(origin_label[2]))."
                    return false
                end
            end
        end

        # Check destination node (compare spatial IDs and time range)
        end_node_code = path[end]
        valid_destination = travel_time_graph.destination_codes[bundle_idx]
        end_label = MetaGraphsNext.label_for(travel_time_graph.graph, end_node_code)
        destination_label = MetaGraphsNext.label_for(
            travel_time_graph.graph, valid_destination
        )
        if end_node_code != valid_destination
            # Tolerant check: spatial ID must match and times must be within bounds
            if end_label[1] != destination_label[1]
                verbose &&
                    @warn "Bundle $(bundle_idx) ends at spatial node $(end_label[1]) instead of valid destination $(destination_label[1])."
                return false
            end
            if is_date_arrival(travel_time_graph)
                # arrival: must end at τ == destination τ (typically 0)
                if end_label[2] != destination_label[2]
                    verbose &&
                        @warn "Bundle $(bundle_idx) ends at time τ=$(end_label[2]) instead of expected $(destination_label[2]) for arrival-mode destination."
                    return false
                end
            else
                # elapsed: end τ must be <= destination τ (max duration) and >= 0
                if end_label[2] < 0 || end_label[2] > destination_label[2]
                    verbose &&
                        @warn "Bundle $(bundle_idx) ends at invalid time τ=$(end_label[2]) for elapsed-mode destination (max τ=$(destination_label[2]))."
                    return false
                end
            end
        end
    end

    # Capacity checks ------------------------------------------------------
    # 1) For bin-packing arcs, ensure no bin exceeds its capacity.
    for (edge, assignment) in sol.assignments
        for b in bins_of(assignment)
            if b.total_size > b.max_capacity + 1e-8
                verbose &&
                    @warn "Bin on edge $(edge) exceeds capacity: $(b.total_size) > $(b.max_capacity)"
                return false
            end
        end
    end

    # 2) For all time-space arcs, ensure commodity size fits arc capacity per mode.
    for (edge, assignment) in sol.assignments
        u, v = edge
        u_label = MetaGraphsNext.label_for(time_space_graph.graph, u)
        v_label = MetaGraphsNext.label_for(time_space_graph.graph, v)
        if MetaGraphsNext.haskey(time_space_graph.graph, u_label, v_label)
            arc = time_space_graph.graph[u_label, v_label]
            if !_capacity_feasible(arc, assignment, (u_label, v_label); verbose)
                return false
            end
        else
            verbose &&
                @warn "TimeSpaceGraph arc for edge $(edge) not found, cannot check capacity."
        end
    end

    return true
end

"""
$TYPEDSIGNATURES

Project a node code from the `TravelTimeGraph` to a node code in the `TimeSpaceGraph` for a specific order.
The projection converts the graph-specific time `τ` (budget or elapsed) into absolute time `t` in the `TimeSpaceGraph`.

# Time Projection Formulas
- If `is_date_arrival = true`: `t = deadline - τ`
- If `is_date_arrival = false`: `t = release + τ`

Throws a `DomainError` if the resulting `t` is outside the instance time horizon `[1, time_horizon_length]`.
"""
function project_to_time_space_graph(
    ttg_node_code::Int, order::Order{is_date_arrival}, instance::Instance
) where {is_date_arrival}
    cache = instance.index_cache
    snode = cache.ttg_spatial[ttg_node_code]
    τ = cache.ttg_tau[ttg_node_code]

    if is_date_arrival
        t = order.time_step - τ
    else
        t = order.time_step + τ
    end

    if !(1 <= t <= instance.time_horizon_length)
        if instance.time_space_graph.wrap_time
            if t > instance.time_horizon_length
                t = t - instance.time_horizon_length
            else
                t = t + instance.time_horizon_length
            end
        else
            throw(
                DomainError(
                    t,
                    "Projected time step out of bounds (τ=$(τ), t=$(t)) for order $(order) and node code $(ttg_node_code)",
                ),
            )
        end
    end

    tsg_code = cache.tsg_code_of[snode, t]
    # tsg_code_of stores 0 where no TSG node exists at (snode, t). Valid
    # projections always land on an existing node (the TSG has a timed copy of
    # every network node for every t in 1:time_horizon_length), so a 0 here means
    # a broken invariant, not normal flow. Throw a clear error instead of letting
    # 0 propagate into downstream graph lookups.
    iszero(tsg_code) && throw(
        DomainError(
            (snode, t),
            "No TimeSpaceGraph node at (spatial=$(snode), t=$(t)) for ttg_node_code=$(ttg_node_code), τ=$(τ)",
        ),
    )
    return tsg_code
end

"""
$TYPEDSIGNATURES

Project bundle paths to order paths on the Time Space Graph.
Returns a Dict mapping Order to a Vector of TSG node codes (Int).
"""
function project_bundle_path_to_order_paths(sol::Solution, instance::Instance)
    order_paths = Dict{Order,Vector{Int}}()

    for (bundle_idx, path) in enumerate(sol.bundle_paths)
        bundle = instance.bundles[bundle_idx]
        for order in bundle.orders
            tsg_path = [
                project_to_time_space_graph(node_code, order, instance) for
                node_code in path
            ]
            order_paths[order] = tsg_path
        end
    end
    return order_paths
end

"""
$TYPEDSIGNATURES

Incrementally add a path (sequence of TTG node codes) for a bundle and update the solution.
This updates `bundle_paths` and the per-edge entries in `assignments`.
"""
function _is_shortcut_arc(::NetworkArc)
    return false
end

function _is_shortcut_arc(arc::NetworkArc{ShortcutArcCost,K}) where {K}
    return travel_time_steps(arc) == 0
end

_is_shortcut_arc(arc::MultiModalArc) = false

"""
$TYPEDSIGNATURES

Ensure `slot.commodities` is in descending order by `.size`, sorting in place
if not already. Sets `slot.sorted = true`. After this returns, the LS hot path
can skip the bin-packing internal sort by passing `presorted=true` to FFD/BFD
helpers.
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
descending order (which is the `Order.commodities` invariant established at
instance construction). When `slot.sorted` is true, this performs an in-place
two-pointer merge in O(`|slot.commodities|` + `|new_commodities|`) and keeps
`slot.sorted = true`. When the slot's order is not known (the fallback case
hit by ad-hoc external constructors), we append and re-sort just like before.

Hot path during LS — replaces the previous `append! + slot.sorted = false`
pattern, which forced the next `_ensure_sorted!` call to re-sort the full
pool. The instrumented LS profile showed that re-sort accounting for ~15% of
LS time at `packing=:frozen`.
"""
function _merge_sorted_into_slot!(
    slot::SingleAssignment{C}, new_commodities::Vector{C}
) where {C<:LightCommodity}
    isempty(new_commodities) && return slot
    if !slot.sorted
        # Fallback for slots not maintained under the invariant. Hot path
        # never enters this branch because every slot starts with sorted=true
        # (0-arg ctor) and we now keep it that way on every add.
        append!(slot.commodities, new_commodities)
        return slot
    end
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

function _update_single_assignment_cost!(
    slot::SingleAssignment{C}, arc_cost::AbstractArcCostFunction
) where {C}
    _ensure_sorted!(slot)
    if arc_cost isa BinPackingArcCost
        bins = compute_bin_assignments(arc_cost, slot.commodities; presorted=true)
        slot.bins = bins
        slot.cost = arc_cost.cost_per_bin * length(bins)
    else
        slot.cost = evaluate(arc_cost, slot.commodities; presorted=true)
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Frozen-bin commit for a single-mode slot. `slot.commodities` has already had
`new_comms` appended by the caller. Instead of re-packing the union (the
`:ffd_union` path via `_update_single_assignment_cost!`), this adds only
`new_comms` to the cached `slot.bins` via first-fit, keeping the existing bins
frozen. The result mirrors `frozen_incremental_count!` exactly, so the committed
bin count matches what the frozen incremental cost predicted.

Dispatch by cost type:
- `BinPackingArcCost`: grow `slot.bins` via `frozen_first_fit_add!` and set
  `slot.cost = cost_per_bin * length(slot.bins)`.
- `SumArcCost`: grow the bin-packing term's `slot.bins` via first-fit and set
  `slot.cost = cost_per_bin * length(slot.bins)` plus `evaluate` of the
  non-bin-packing terms (linear in volume, hence mode-independent).
- any other (linear, shortcut): identical to `_update_single_assignment_cost!`.
"""
function _frozen_commit_single_assignment!(
    slot::SingleAssignment{C}, arc_cost::BinPackingArcCost, new_comms::Vector{C}
) where {C}
    frozen_first_fit_add!(slot.bins, Float64(arc_cost.bin_capacity), new_comms)
    slot.cost = arc_cost.cost_per_bin * length(slot.bins)
    return nothing
end

function _frozen_commit_single_assignment!(
    slot::SingleAssignment{C}, arc_cost::SumArcCost, new_comms::Vector{C}
) where {C}
    total = 0.0
    for t in arc_cost.terms
        if t isa BinPackingArcCost
            frozen_first_fit_add!(slot.bins, Float64(t.bin_capacity), new_comms)
            total += t.cost_per_bin * length(slot.bins)
        else
            total += evaluate(t, slot.commodities)
        end
    end
    slot.cost = total
    return nothing
end

function _frozen_commit_single_assignment!(
    slot::SingleAssignment{C}, arc_cost::AbstractArcCostFunction, ::Vector{C}
) where {C}
    # Non-bin-packing costs are identical under both packing modes.
    return _update_single_assignment_cost!(slot, arc_cost)
end

"""
$TYPEDSIGNATURES

Partition `new_comms` across the modes of `arc` in cheapest-first order, filling
each mode up to its remaining capacity before moving to the next.

Returns `(partition, overflow)` where `partition[i]` is the subset of
`new_comms` assigned to `arc.modes[i]`, and `overflow` is `true` if the combined
remaining capacity across all modes is insufficient to absorb `new_comms`. When
`overflow` is `true`, `partition` contains only the items that could legitimately
be placed (the leftover is not stuffed onto any mode).
"""
function _fill_then_spill_partition(
    arc::MultiModalArc, existing_per_mode::Vector{Vector{C}}, new_comms::Vector{C}
) where {C<:LightCommodity}
    mode_costs = [
        incremental_cost(arc.modes[i].cost, existing_per_mode[i], new_comms) for
        i in eachindex(arc.modes)
    ]
    sorted_indices = sortperm(mode_costs)

    per_mode_new = [C[] for _ in eachindex(arc.modes)]
    remaining = copy(new_comms)

    for mode_idx in sorted_indices
        isempty(remaining) && break
        mode = arc.modes[mode_idx]
        existing_size = sum(c.size for c in existing_per_mode[mode_idx]; init=0.0)
        cap_left = Float64(mode.capacity) - existing_size

        placed = C[]
        still_remaining = C[]
        placed_size = 0.0

        for c in remaining
            if placed_size + c.size <= cap_left + 1e-8
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

function _fill_then_spill_assign!(
    edge::Tuple{Int,Int},
    arc::MultiModalArc,
    assignment::MultiAssignment{C},
    new_commodities::Vector{C},
) where {C<:LightCommodity}
    existing_per_mode = [slot.commodities for slot in assignment.per_mode]
    partition, overflow = _fill_then_spill_partition(
        arc, existing_per_mode, new_commodities
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
            arc.modes[i], assignment.per_mode[i].commodities, new_commodities
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
    return existing_size + new_size <= mode.capacity + 1e-8
end

function _capacity_feasible(
    arc::NetworkArc, assignment::AbstractArcAssignment, arc_labels; verbose::Bool
)
    arc.capacity == typemax(Int) && return true
    total_size = sum(c.size for c in commodities_of(assignment); init=0.0)
    if total_size > arc.capacity + 1e-8
        verbose &&
            @warn "Arc $(arc_labels) exceeds capacity: $(total_size) > $(arc.capacity)"
        return false
    end
    return true
end

function _capacity_feasible(
    arc::MultiModalArc, assignment::MultiAssignment, arc_labels; verbose::Bool
)
    for (i, (mode, slot)) in enumerate(zip(arc.modes, assignment.per_mode))
        mode.capacity == typemax(Int) && continue
        total_size = sum(c.size for c in slot.commodities; init=0.0)
        if total_size > mode.capacity + 1e-8
            verbose &&
                @warn "Arc $(arc_labels) mode $(i) exceeds capacity: $(total_size) > $(mode.capacity)"
            return false
        end
    end
    return true
end

"""
$TYPEDSIGNATURES

Remove leading or trailing shortcut nodes from a TTG path, depending on the graph's time semantics.
"""
function _remove_shortcuts_from_path!(path::Vector{Int}, ttg::TravelTimeGraph)
    # Remove leading shortcuts for arrival-based graphs, trailing for elapsed-time graphs
    if length(path) < 2
        return nothing
    end

    if is_date_arrival(ttg)
        # Remove destination nodes of starting shortcut edges (keep the first timed node)
        while length(path) >= 2
            src, dst = path[1], path[2]
            u_label = MetaGraphsNext.label_for(ttg.graph, src)
            v_label = MetaGraphsNext.label_for(ttg.graph, dst)
            if !haskey(ttg.graph, u_label, v_label)
                break
            end
            arc = ttg.graph[u_label, v_label]
            # Only remove if the arc is a shortcut AND stays on the same spatial node
            if _is_shortcut_arc(arc) && u_label[1] == v_label[1]
                # Remove the leading node so the path starts at the first valid timed
                # node (consistent with existing `remove_shortcuts!` behaviour)
                deleteat!(path, 1)
            else
                break
            end
        end
    else
        # Remove destination nodes of trailing shortcut edges (pop trailing shortcut nodes)
        while length(path) >= 2
            src, dst = path[end - 1], path[end]
            u_label = MetaGraphsNext.label_for(ttg.graph, src)
            v_label = MetaGraphsNext.label_for(ttg.graph, dst)
            if !haskey(ttg.graph, u_label, v_label)
                break
            end
            arc = ttg.graph[u_label, v_label]
            if _is_shortcut_arc(arc) && u_label[1] == v_label[1]
                pop!(path) # remove trailing shortcut node
            else
                break
            end
        end
    end
    return nothing
end

"""
$TYPEDSIGNATURES

Add bundle path `path` for bundle `bundle_idx` to the solution `current_solution`.
This updates the `bundle_paths` and the `assignments` for all arcs along the path.

Returns the cost increase produced by adding `path` (a non-negative `Float64`).
The increase is computed as the sum of per-edge cost changes via
`_update_single_assignment_cost!`.
"""
function add_bundle_path!(
    current_solution::Solution{C},
    instance::Instance,
    bundle_idx::Int,
    path::Vector{Int};
    mode_selector::AbstractModeSelector=CheapestMode(),
    packing::Symbol=:frozen,
) where {C}
    # Remove potential shortcut edges before storing the path (TTG may contain shortcuts).
    _remove_shortcuts_from_path!(path, instance.travel_time_graph)
    current_solution.bundle_paths[bundle_idx] = path
    bundle = instance.bundles[bundle_idx]
    cache = instance.index_cache
    cost_delta = 0.0

    # Orders within a bundle have distinct delivery time steps in 1:H so they
    # project to distinct TSG edges on any arc, even under wrap_time. Each
    # (order, arc) pair therefore touches a unique TSG edge, so no per-edge
    # grouping is needed (same zero-collision argument as the forward
    # `compute_ttg_edge_*` rewrite).
    for order in bundle.orders
        for k in 1:(length(path) - 1)
            u_tsg = project_to_time_space_graph(path[k], order, instance)
            v_tsg = project_to_time_space_graph(path[k + 1], order, instance)
            su = cache.tsg_spatial[u_tsg]
            sv = cache.tsg_spatial[v_tsg]
            arc = cache.arc_of[(su, sv)]
            edge = (u_tsg, v_tsg)
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
    return cost_delta
end

"""
$TYPEDSIGNATURES

Reverse the effect of `add_bundle_path!` for bundle `bundle_idx`. Drops the
bundle's commodities from every TSG edge along the stored path, then clears
`bundle_paths[bundle_idx]`. Returns the cost decrease produced by the removal
(a non-positive `Float64` whose magnitude equals the dropped cost contribution
of the bundle on its path). Returns `0.0` when the bundle path is already
empty.

Per-edge details:
- On `BinPackingArcCost` edges, bins are recomputed from scratch via
  `compute_bin_assignments`, so the stored `bins` and `cost` reflect the
  reduced commodity set.
- On `LinearArcCost` edges, `cost` is recomputed via `evaluate`.
- Commodities are matched by `==`. By construction (see
  `build_instance`), two bundles with different `(origin_id, destination_id,
  group_key)` cannot share `==`-equal commodities, so the match is
  unambiguous across bundles.
- For `MultiAssignment` edges, modes are scanned in order. Each commodity is
  dropped from the first mode that contains it, which is always the mode
  where `add_bundle_path!` placed it (no other bundle's commodities can
  alias under `==`).

Assignment dict entries are kept even when their commodity vector goes to
zero, so subsequent reinsertion can reuse them without re-keying. An entry
whose commodities are empty contributes `0` to `cost(sol)` via
`_update_single_assignment_cost!`.

Throws `ArgumentError` if any of the bundle's commodities are not found on
the expected TSG edges. That should never happen when the bundle's stored
path is consistent with how it was added.
"""
function remove_bundle_path!(
    current_solution::Solution{C}, instance::Instance, bundle_idx::Int
) where {C}
    path = current_solution.bundle_paths[bundle_idx]
    isempty(path) && return 0.0
    bundle = instance.bundles[bundle_idx]
    cache = instance.index_cache
    cost_delta = 0.0

    # Orders within a bundle have distinct delivery time steps in 1:H so they
    # project to distinct TSG edges on any arc, even under wrap_time (same
    # zero-collision argument as the forward `compute_ttg_edge_*` rewrite).
    # The cost delta is therefore an additive sum over (order, arc) pairs
    # without any per-edge grouping.
    for order in bundle.orders
        for k in 1:(length(path) - 1)
            u_tsg = project_to_time_space_graph(path[k], order, instance)
            v_tsg = project_to_time_space_graph(path[k + 1], order, instance)
            su = cache.tsg_spatial[u_tsg]
            sv = cache.tsg_spatial[v_tsg]
            arc = cache.arc_of[(su, sv)]
            edge = (u_tsg, v_tsg)
            assignment = current_solution.assignments[edge]
            cost_delta += _remove_commodities_from_assignment!(
                assignment, arc, order.commodities
            )
        end
    end

    current_solution.bundle_paths[bundle_idx] = Int[]
    return cost_delta
end

function _remove_commodities_from_assignment!(
    assignment::SingleAssignment{C}, arc::NetworkArc, removed_comms::Vector{C}
) where {C<:LightCommodity}
    before = assignment.cost
    remaining = copy(removed_comms)
    _drain_first_matches!(assignment.commodities, remaining)
    if !isempty(remaining)
        throw(
            ArgumentError(
                "remove_bundle_path!: $(length(remaining)) commodities not found in single-mode assignment",
            ),
        )
    end
    _update_single_assignment_cost!(assignment, arc.cost)
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
            _update_single_assignment_cost!(slot, arc.modes[i].cost)
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

"""
    Solution(bundle_paths, instance; mode_selector=CheapestMode())

Construct a `Solution` from bundle paths and an instance.
This constructor precomputes commodity distributions on arcs, bin-packing results, and total cost.
"""
function Solution(
    bundle_paths::Vector{Vector{Int}},
    instance::Instance{Bundle{Order{IDA,I}}};
    mode_selector::AbstractModeSelector=CheapestMode(),
) where {IDA,I}
    (; time_space_graph, bundles) = instance

    C = LightCommodity{IDA,I}
    assignments = Dict{Tuple{Int,Int},Union{SingleAssignment{C},MultiAssignment{C}}}()

    # Clean paths (remove TTG shortcut edges) before projecting
    cleaned_paths = [copy(p) for p in bundle_paths]
    for (bundle_idx, ttg_path) in enumerate(cleaned_paths)
        _remove_shortcuts_from_path!(ttg_path, instance.travel_time_graph)
        bundle = bundles[bundle_idx]

        # Same bucketing as in `add_bundle_path!`: combine all the bundle's
        # commodities per TSG edge before consulting the mode selector.
        tsg_edge_to_new_commodities = Dict{Tuple{Int,Int},Vector{C}}()
        for order in bundle.orders
            tsg_path = [
                project_to_time_space_graph(node_code, order, instance) for
                node_code in ttg_path
            ]
            for i in 1:(length(tsg_path) - 1)
                edge = (tsg_path[i], tsg_path[i + 1])
                append!(get!(tsg_edge_to_new_commodities, edge, C[]), order.commodities)
            end
        end

        for (edge, new_comms) in tsg_edge_to_new_commodities
            u_label = MetaGraphsNext.label_for(time_space_graph.graph, edge[1])
            v_label = MetaGraphsNext.label_for(time_space_graph.graph, edge[2])
            if !MetaGraphsNext.haskey(time_space_graph.graph, u_label, v_label)
                @warn "Arc ($u_label, $v_label) not found in TimeSpaceGraph"
                continue
            end
            arc = time_space_graph.graph[u_label, v_label]
            _add_order_to_assignment!(assignments, edge, arc, new_comms, mode_selector)
        end
    end

    return Solution{C}(cleaned_paths, assignments)
end

"""
    cost(sol)

Compute the cost of the solution by summing individual arc costs.
"""
function cost(sol::Solution)
    return sum(cost_of(a) for a in values(sol.assignments); init=0.0)
end

"""
$TYPEDSIGNATURES

Compute the cost of the solution (legacy signature for compatibility).
"""
function cost(sol::Solution, instance::Instance)
    return cost(sol)
end

"""
$TYPEDSIGNATURES

Total cost of `sol` including both arc costs (sum over assignments) and
destination-node costs (sum over each bundle's path, charging
`evaluate(dst.node_cost, comms_on_edge)` for each TSG edge in the path).

Use this when comparing against external systems that include node costs in
their total (for example STP's `compute_cost`). For arc-only cost use `cost(sol)`.
"""
function cost_with_nodes(sol::Solution{C}, instance::Instance) where {C}
    total = cost(sol)
    tsg = instance.time_space_graph
    for (i, path) in enumerate(sol.bundle_paths)
        isempty(path) && continue
        bundle = instance.bundles[i]
        for order in bundle.orders
            tsg_path = [
                project_to_time_space_graph(node_code, order, instance) for
                node_code in path
            ]
            for k in 1:(length(tsg_path) - 1)
                v_tsg = tsg_path[k + 1]
                v_label = MetaGraphsNext.label_for(tsg.graph, v_tsg)
                dst_node = instance.network_graph.graph[v_label[1]]
                total += evaluate(dst_node.node_cost, order.commodities)
            end
        end
    end
    return total
end
