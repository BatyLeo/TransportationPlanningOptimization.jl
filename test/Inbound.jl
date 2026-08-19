"""
    Inbound

Test helper module for reading and parsing inbound instances from CSV files.
Contains constants for column mappings and functions for loading test data.
"""
module Inbound

using CSV
using DataFrames
using Dates
using TransportationPlanningOptimization

const TPO = TransportationPlanningOptimization

# Node CSV column mappings
const NODE_ID = :point_account
const NODE_COST = :point_m3_cost
const NODE_CAPACITY = :point_m3_capacity
const NODE_TYPE = :point_type

# Arc CSV column mappings
const ALLOWED_ARC_TYPES = [:direct, :outsource, :cross_plat, :delivery, :oversea, :shortcut]
const ARC_ORIGIN_ID = :src_account
const ARC_DESTINATION_ID = :dst_account
const ARC_SHIPMENT_COST = :shipment_cost
const ARC_CAPACITY = :capacity
const ARC_TYPE = :leg_type
const ARC_ORIGIN_TYPE = :src_type
const ARC_DESTINATION_TYPE = :dst_type
const ARC_DISTANCE = :distance
const ARC_TRAVEL_TIME = :travel_time
const ARC_CARBON_COST = :carbon_cost

# Commodity CSV column mappings
const COMMODITY_ORIGIN_ID = :supplier_account
const COMMODITY_DESTINATION_ID = :customer_account
const COMMODITY_SIZE = :size
const COMMODITY_ARRIVAL_DATE = :delivery_date
const COMMODITY_MAX_DELIVERY_TIME = :max_delivery_time
const COMMODITY_QUANTITY = :quantity
const COMMODITY_LEAD_TIME_COST = :lead_time_cost

# STP integer scaling factor for commodity sizes and arc capacities
const VOLUME_FACTOR = 100

"""
    InboundNodeInfo

Test data structure for node metadata in inbound instances.
"""
struct InboundNodeInfo end

"""
    InboundArcInfo

Test data structure for arc metadata in inbound instances.
"""
struct InboundArcInfo
    arc_type::Symbol
end

"""
    InboundCommodityInfo

Per-commodity Inbound info. Carries the stock cost read from the
`lead_time_cost` column of the commodities CSV. Stored on `Commodity.info` and
read by `StockArcCost.evaluate`.
"""
struct InboundCommodityInfo
    stock_cost::Float64
end

"""
    CarbonArcCost(carbon_per_unit_volume)

Carbon cost on an arc. STP charges `carbonCost * volume / capacity` per order
(`Algorithms/Utils/greedy_utils.jl:28`). We precompute the per-unit-volume
rate `carbon_per_unit_volume = carbonCost / capacity` at parse time so the
runtime formula is plain `factor * volume`.
"""
struct CarbonArcCost <: TPO.AbstractArcCostFunction
    carbon_per_unit_volume::Float64
end

function TPO.evaluate(
    c::CarbonArcCost, comms::Vector{<:TPO.LightCommodity}; presorted::Bool=false
)
    return c.carbon_per_unit_volume * sum(x.size for x in comms; init=0.0)
end
@inline function TPO._evaluate_with_total_size(
    c::CarbonArcCost,
    ::Vector{<:TPO.LightCommodity},
    total_size::Float64;
    presorted::Bool=false,
)
    return c.carbon_per_unit_volume * total_size
end
function TPO.incremental_cost(
    c::CarbonArcCost, _::Vector{C}, new::Vector{C}
) where {C<:TPO.LightCommodity}
    return c.carbon_per_unit_volume * sum(x.size for x in new; init=0.0)
end
function TPO.lower_bound_incremental_cost(
    c::CarbonArcCost, e::Vector{C}, n::Vector{C}
) where {C<:TPO.LightCommodity}
    return TPO.incremental_cost(c, e, n)
end
function TPO.incremental_cost_with_size(
    c::CarbonArcCost, ::Vector{C}, ::Vector{C}, new_total_size::Float64
) where {C<:TPO.LightCommodity}
    return c.carbon_per_unit_volume * new_total_size
end

"""
    StockArcCost(distance)

Stock cost on an arc. STP charges `arcData.distance * order.stockCost` per
order (`Algorithms/Utils/greedy_utils.jl:34`), where `order.stockCost =
sum(c.stockCost for c in order.content)`. We carry the arc's distance (km)
duplicated from the leg CSV and read per-commodity stock cost from
`commodity.info.stock_cost`.

Requires `Commodity.info` to be an `InboundCommodityInfo` (or any struct
exposing `stock_cost`). Calling `evaluate` on commodities without that field
errors at the property access.
"""
struct StockArcCost <: TPO.AbstractArcCostFunction
    distance::Float64
end

function TPO.evaluate(
    c::StockArcCost, comms::Vector{<:TPO.LightCommodity}; presorted::Bool=false
)
    return c.distance * sum(x.info.stock_cost for x in comms; init=0.0)
end
function TPO.incremental_cost(
    c::StockArcCost, _::Vector{C}, new::Vector{C}
) where {C<:TPO.LightCommodity}
    return c.distance * sum(x.info.stock_cost for x in new; init=0.0)
end
function TPO.lower_bound_incremental_cost(
    c::StockArcCost, e::Vector{C}, n::Vector{C}
) where {C<:TPO.LightCommodity}
    return TPO.incremental_cost(c, e, n)
end

"""
Node volume / platform cost charged on the destination node of each
traversed arc. STP charges `dstData.volumeCost * volume / VOLUME_FACTOR`. TPO
uses raw m3 so the formula simplifies to `volume_cost * total_size`.
"""
struct NodeVolumeCost <: TPO.AbstractNodeCostFunction
    volume_cost::Float64
end

function TPO.evaluate(c::NodeVolumeCost, comms::Vector{<:TPO.LightCommodity})
    return c.volume_cost * sum(x.size for x in comms; init=0.0)
end
@inline function TPO._evaluate_with_total_size(
    c::NodeVolumeCost,
    ::Vector{<:TPO.LightCommodity},
    total_size::Float64;
    presorted::Bool=false,
)
    return c.volume_cost * total_size
end
function TPO.incremental_cost(
    c::NodeVolumeCost, _::Vector{C}, new::Vector{C}
) where {C<:TPO.LightCommodity}
    return c.volume_cost * sum(x.size for x in new; init=0.0)
end
function TPO.lower_bound_incremental_cost(
    c::NodeVolumeCost, e::Vector{C}, n::Vector{C}
) where {C<:TPO.LightCommodity}
    return TPO.incremental_cost(c, e, n)
end
function TPO.incremental_cost_with_size(
    c::NodeVolumeCost, ::Vector{C}, ::Vector{C}, new_total_size::Float64
) where {C<:TPO.LightCommodity}
    return c.volume_cost * new_total_size
end

"""
    parse_inbound_instance(node_file::String, leg_file::String, commodity_file::String)

Read an inbound instance from three CSV files: nodes, legs, and commodities.

Returns a named tuple `(; nodes, arcs, commodities)` containing:
- `nodes::Vector{NetworkNode}` - Network nodes parsed from node_file
- `arcs::Vector{NetworkArc}` - Network arcs parsed from leg_file
- `commodities::Vector{Commodity}` - Commodities parsed from commodity_file

The function performs deduplication of arcs (keeps only the first arc for each 
origin-destination pair) and handles heterogeneous cost function types.
"""
function parse_inbound_instance(
    node_file::String, leg_file::String, commmodity_file::String
)
    df_nodes = DataFrame(CSV.File(node_file; stringtype=String))
    df_legs = DataFrame(CSV.File(leg_file; stringtype=String))
    df_commodities = DataFrame(CSV.File(commmodity_file; stringtype=String))

    nodes = map(eachrow(df_nodes)) do row
        node_type_symbol = if row[NODE_TYPE] == "supplier"
            :origin
        elseif row[NODE_TYPE] == "plant"
            :destination
        else
            :other
        end

        NetworkNode(;
            id=string(row[NODE_ID]),
            node_type=node_type_symbol,
            cost=Float64(row[NODE_COST]),
            capacity=Int(row[NODE_CAPACITY]),
            node_cost=NodeVolumeCost(Float64(row[NODE_COST]) / VOLUME_FACTOR),
        )
    end

    leg_fields_to_check = [
        ARC_ORIGIN_ID,
        ARC_DESTINATION_ID,
        ARC_SHIPMENT_COST,
        ARC_CAPACITY,
        ARC_TYPE,
        ARC_ORIGIN_TYPE,
        ARC_DESTINATION_TYPE,
        ARC_DISTANCE,
        ARC_TRAVEL_TIME,
        ARC_CARBON_COST,
    ]
    filter!(row -> all(col -> !ismissing(row[col]), leg_fields_to_check), df_legs)

    raw_arcs = map(eachrow(df_legs)) do row
        shipment_cost = Float64(row[ARC_SHIPMENT_COST])
        capacity = round(Int, row[ARC_CAPACITY] * VOLUME_FACTOR)
        carbon_cost = Float64(row[ARC_CARBON_COST])
        distance = Float64(row[ARC_DISTANCE])
        base_cost = if row.is_linear
            LinearArcCost(shipment_cost / capacity)
        else
            BinPackingArcCost(shipment_cost, capacity)
        end
        cost_tuple = (
            base_cost, CarbonArcCost(carbon_cost / capacity), StockArcCost(distance)
        )
        return Arc(;
            origin_id=string(row[ARC_ORIGIN_ID]),
            destination_id=string(row[ARC_DESTINATION_ID]),
            travel_time=Week(row[ARC_TRAVEL_TIME]),
            cost=cost_tuple,
            info=InboundArcInfo(Symbol(row[ARC_TYPE])),
        )
    end
    # keep only the first arc for each (origin_id, destination_id) pair
    seen = Set{Tuple{String,String}}()
    nb_duplicates = 0
    raw_arcs = filter(arc -> begin
        pair = (arc.origin_id, arc.destination_id)
        if pair in seen
            nb_duplicates += 1
            false
        else
            push!(seen, pair)
            true
        end
    end, raw_arcs)
    if nb_duplicates > 0
        @warn "$nb_duplicates duplicate arcs found; only the first occurrence for each (origin, destination) pair is kept."
    end
    # filter!(arc -> arc.info.arc_type in ALLOWED_ARC_TYPES, raw_arcs)
    # arcs = collect_arcs((LinearArcCost, BinPackingArcCost), raw_arcs)

    commodities = map(eachrow(df_commodities)) do row
        Commodity(;
            origin_id=string(row[COMMODITY_ORIGIN_ID]),
            destination_id=string(row[COMMODITY_DESTINATION_ID]),
            size=Float64(max(1, round(Int, row[COMMODITY_SIZE] * VOLUME_FACTOR))),
            quantity=Int(row[COMMODITY_QUANTITY]),
            arrival_date=DateTime(row[COMMODITY_ARRIVAL_DATE], "yyyy-mm-dd HH:MM:SS+00:00"),
            max_delivery_time=Week(row[COMMODITY_MAX_DELIVERY_TIME]),
            info=InboundCommodityInfo(Float64(row[COMMODITY_LEAD_TIME_COST])),
        )
    end

    return (; nodes, arcs=raw_arcs, commodities)
end

using Random
using SparseArrays
using JuMP
using HiGHS
using MetaGraphsNext: MetaGraphsNext

# ─── Perturbation types mirroring STP's neighborhoods ───

"""
    PlantPerturbation

Mirrors STP's `:single_plant` neighborhood.
Selects all bundles delivering to a randomly chosen plant (destination node),
removes them, and reinserts in random order via Dijkstra.
"""
struct PlantPerturbation <: TPO.AbstractPerturbation end

"""
    SupplierPerturbation

Mirrors STP's supplier-based bundle selection.
Selects all bundles originating from a randomly chosen supplier,
removes them, and reinserts in random order via Dijkstra.
"""
struct SupplierPerturbation <: TPO.AbstractPerturbation end

function _group_bundles_by(bundles, key_fn)
    groups = Dict{String,Vector{Int}}()
    for (i, b) in enumerate(bundles)
        k = key_fn(b)
        push!(get!(groups, k, Int[]), i)
    end
    return groups
end

function _perturbate_bundle_group!(
    sol::TPO.Solution,
    instance::TPO.Instance,
    bundle_idxs::Vector{Int};
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    isempty(bundle_idxs) && return (0.0, 0)
    before = TPO.cost(sol)
    snap = TPO.snapshot_solution(sol, instance)

    # Remove all selected bundles
    for idx in bundle_idxs
        isempty(sol.bundle_paths[idx]) && continue
        TPO.remove_bundle_path!(sol, instance, idx)
    end

    # Reinsert in random order
    for idx in shuffle(rng, bundle_idxs)
        TPO.insert_bundle!(sol, instance, idx)
    end

    after = TPO.cost(sol)

    # Revert if cost increased by more than 1.5% (matches STP's objTol)
    if after > before * 1.015
        TPO.restore_solution!(sol, snap, instance)
        return (0.0, 0)
    end
    return (before - after, length(bundle_idxs))
end

function TPO.perturbate!(
    sol::TPO.Solution,
    instance::TPO.Instance,
    ::PlantPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    groups = _group_bundles_by(instance.bundles, b -> b.destination_id)
    isempty(groups) && return (0.0, 0)
    plant = rand(rng, collect(keys(groups)))
    bundle_idxs = groups[plant]
    verbose && @info "PlantPerturbation" plant n_bundles = length(bundle_idxs)
    return _perturbate_bundle_group!(sol, instance, bundle_idxs; rng, verbose)
end

function TPO.perturbate!(
    sol::TPO.Solution,
    instance::TPO.Instance,
    ::SupplierPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    groups = _group_bundles_by(instance.bundles, b -> b.origin_id)
    isempty(groups) && return (0.0, 0)
    supplier = rand(rng, collect(keys(groups)))
    bundle_idxs = groups[supplier]
    verbose && @info "SupplierPerturbation" supplier n_bundles = length(bundle_idxs)
    return _perturbate_bundle_group!(sol, instance, bundle_idxs; rng, verbose)
end

# ─── MILP-based perturbation mirroring STP's LNS ───

"""
    MILPPlantPerturbation(; max_variables=1_000_000)

Arc-flow MILP perturbation mirroring STP's `:single_plant` neighborhood.
Selects bundles delivering to a randomly chosen plant, builds an arc-flow
MILP with packing constraints on the TimeSpaceGraph common arcs, solves
it with HiGHS, and applies the resulting paths.

Requires JuMP and HiGHS to be loaded before `using Inbound`.
"""
struct MILPPlantPerturbation <: TPO.AbstractPerturbation
    max_variables::Int
    optimizer_factory::Any  # () -> optimizer, or nothing for auto-detect
end
function MILPPlantPerturbation(; max_variables::Int=50_000, optimizer=nothing)
    return MILPPlantPerturbation(max_variables, optimizer)
end

function _make_optimizer()
    try
        return TPO.gurobi_optimizer()
    catch
        return HiGHS.Optimizer()
    end
end

function _is_gurobi(model)
    name = lowercase(string(typeof(JuMP.backend(model))))
    return occursin("gurobi", name)
end

# ── Helpers for identifying arc cost types ──

_bp_cost_of(cost::TPO.BinPackingArcCost) = cost
_bp_cost_of(cost::TPO.SumArcCost) = TPO._find_bin_packing(cost)
_bp_cost_of(::TPO.AbstractArcCostFunction) = nothing
_bp_cost_of(::TPO.ShortcutArcCost) = nothing

_is_shortcut(cost::TPO.ShortcutArcCost) = true
_is_shortcut(::TPO.AbstractArcCostFunction) = false
function _is_shortcut(arc::TPO.NetworkArc)
    return _is_shortcut(arc.cost) && arc.travel_time_steps == 0
end

# Non-packing cost per order on an arc (everything except BinPackingArcCost).
# For linear arcs this includes the linear transport cost.
_non_bp_cost(cost::TPO.BinPackingArcCost, comms) = 0.0
_non_bp_cost(cost::TPO.LinearArcCost, comms) = TPO.evaluate(cost, comms)
_non_bp_cost(cost::TPO.ShortcutArcCost, comms) = 0.0
_non_bp_cost(cost::CarbonArcCost, comms) = TPO.evaluate(cost, comms)
_non_bp_cost(cost::StockArcCost, comms) = TPO.evaluate(cost, comms)
_non_bp_cost(cost::TPO.AbstractArcCostFunction, comms) = TPO.evaluate(cost, comms)
function _non_bp_cost(cost::TPO.SumArcCost, comms)
    total = 0.0
    for term in cost.terms
        term isa TPO.BinPackingArcCost && continue
        total += _non_bp_cost(term, comms)
    end
    return total
end

# ── Collect "common" TSG arcs (those with BinPackingArcCost) ──

function _collect_common_tsg_arcs(instance)
    cache = instance.index_cache
    H = instance.time_horizon_length
    wrap = instance.time_space_graph.wrap_time

    common_arcs = Tuple{Int,Int}[]
    arc_bp = Dict{Tuple{Int,Int},TPO.BinPackingArcCost}()

    for ((su, sv), arc) in cache.arc_of
        bp = _bp_cost_of(arc.cost)
        bp === nothing && continue
        for t in 1:H
            dest_t = t + arc.travel_time_steps
            if dest_t > H
                wrap || continue
                dest_t -= H
            end
            u_tsg = cache.tsg_code_of[su, t]
            v_tsg = cache.tsg_code_of[sv, dest_t]
            (iszero(u_tsg) || iszero(v_tsg)) && continue
            push!(common_arcs, (u_tsg, v_tsg))
            arc_bp[(u_tsg, v_tsg)] = bp
        end
    end
    return common_arcs, arc_bp
end

# ── Compute current loads on common TSG arcs, excluding selected bundles ──

function _compute_tsg_loads(sol, instance, bundle_idxs, common_arcs)
    cache = instance.index_cache
    # Total current load from sol.assignments
    loads = Dict{Tuple{Int,Int},Float64}()
    for (u_tsg, v_tsg) in common_arcs
        assignment = get(sol.assignments, (u_tsg, v_tsg), nothing)
        if assignment !== nothing
            loads[(u_tsg, v_tsg)] = TPO.total_size_of(assignment)
        else
            loads[(u_tsg, v_tsg)] = 0.0
        end
    end

    # Subtract load from selected bundles
    ttg = instance.travel_time_graph
    for b in bundle_idxs
        path = sol.bundle_paths[b]
        isempty(path) && continue
        bundle = instance.bundles[b]
        for order in bundle.orders
            for k in 1:(length(path) - 1)
                u_tsg = TPO.project_to_time_space_graph(path[k], order, instance)
                v_tsg = TPO.project_to_time_space_graph(path[k + 1], order, instance)
                edge = (u_tsg, v_tsg)
                if haskey(loads, edge)
                    loads[edge] -= order.total_size
                end
            end
        end
    end
    return loads
end

# ── Select bundles by plant (destination) ──

function _select_bundles_by_plant(
    instance; rng::Random.AbstractRNG=Random.default_rng(), max_var::Int=1_000_000
)
    ttg = instance.travel_time_graph
    cache = instance.index_cache
    ng = instance.network_graph.graph

    # Group bundles by destination node ID
    plant_groups = Dict{String,Vector{Int}}()
    for (i, b) in enumerate(instance.bundles)
        push!(get!(plant_groups, b.destination_id, Int[]), i)
    end

    # Approximate number of tau variables (common TSG arcs)
    n_common = 0
    for ((su, sv), arc) in cache.arc_of
        if _bp_cost_of(arc.cost) !== nothing
            n_common += instance.time_horizon_length
        end
    end

    small_instance = length(instance.bundles) < 800
    eff_max_var = small_instance ? min(max_var, 50_000) : max_var

    selected = Int[]
    n_var = n_common

    for plant in shuffle(rng, collect(keys(plant_groups)))
        for b in shuffle(rng, plant_groups[plant])
            n_arc = length(ttg.bundle_arcs[b])
            if n_var + n_arc <= eff_max_var
                push!(selected, b)
                n_var += n_arc
            end
        end
        n_var > 0.9 * eff_max_var && return selected
    end
    return selected
end

# ── Compute per-bundle non-packing cost on a TTG arc (for MILP objective) ──

function _milp_arc_cost(instance, bundle_idx, u_ttg, v_ttg)
    cache = instance.index_cache
    su = cache.ttg_spatial[u_ttg]
    sv = cache.ttg_spatial[v_ttg]
    su == sv && return 1e-5  # shortcut

    arc = cache.arc_of[(su, sv)]
    bundle = instance.bundles[bundle_idx]

    cost = 0.0
    for order in bundle.orders
        cost += _non_bp_cost(arc.cost, order.commodities)
        cost += TPO.evaluate(cache.node_cost_of[sv], order.commodities)
    end

    # For linear arcs (no bin packing), the transport cost is already in _non_bp_cost.
    # For outsource/direct in STP, the per-order truck cost is added.
    # In TPO, LinearArcCost.evaluate already gives cost_per_unit_size * volume,
    # which is the continuous relaxation of ceil(volume/capacity) * shipment_cost.
    return max(cost, 1e-5)
end

# ── Build and solve the arc-flow MILP ──

function _solve_arc_flow_milp(
    instance,
    sol,
    bundle_idxs,
    common_arcs,
    arc_bp,
    loads;
    verbose::Bool=false,
    time_limit::Float64=60.0,
    optimizer_factory=nothing,
)
    ttg = instance.travel_time_graph
    cache = instance.index_cache

    small_instance = length(instance.bundles) < 800
    actual_time_limit = small_instance ? time_limit * 0.5 : time_limit

    opt = optimizer_factory === nothing ? _make_optimizer() : optimizer_factory()
    model = JuMP.Model(() -> opt)
    use_gurobi = _is_gurobi(model)
    JuMP.set_optimizer_attribute(model, use_gurobi ? "MIPGap" : "mip_rel_gap", 0.001)
    JuMP.set_time_limit_sec(model, actual_time_limit)
    !verbose && JuMP.set_silent(model)

    # ── Variables ──
    # x[b, (u,v)] ∈ {0,1} for each bundle and its TTG arcs
    x = Dict{Tuple{Int,Tuple{Int,Int}},JuMP.VariableRef}()
    for b in bundle_idxs
        for arc in ttg.bundle_arcs[b]
            x[(b, arc)] = JuMP.@variable(model, binary = true)
        end
    end

    # tau[(u_tsg, v_tsg)] ∈ Z+ for each common TSG arc
    tau = Dict{Tuple{Int,Int},JuMP.VariableRef}()
    for edge in common_arcs
        tau[edge] = JuMP.@variable(model, integer = true, lower_bound = 0)
    end

    verbose &&
        @info "MILP" solver = (use_gurobi ? "Gurobi" : "HiGHS") n_x_vars = length(x) n_tau_vars = length(
            tau
        )

    # ── Path constraints (flow conservation) ──
    for b in bundle_idxs
        flow_expr = Dict{Int,JuMP.AffExpr}()

        origin = ttg.origin_codes[b]
        destination = ttg.destination_codes[b]
        flow_expr[origin] = JuMP.AffExpr(1.0)
        flow_expr[destination] = JuMP.AffExpr(-1.0)

        for arc in ttg.bundle_arcs[b]
            u, v = arc
            expr_u = get!(flow_expr, u, JuMP.AffExpr(0.0))
            JuMP.add_to_expression!(expr_u, -1.0, x[(b, arc)])
            expr_v = get!(flow_expr, v, JuMP.AffExpr(0.0))
            JuMP.add_to_expression!(expr_v, 1.0, x[(b, arc)])
        end

        for (node, expr) in flow_expr
            JuMP.@constraint(model, expr == 0)
        end
    end

    # ── Packing constraints ──
    # For each common TSG arc: background_load + sum(bundle volume * x) <= tau * capacity
    pack_expr = Dict{Tuple{Int,Int},JuMP.AffExpr}()
    for edge in common_arcs
        bp = arc_bp[edge]
        bg_load = get(loads, edge, 0.0)
        pack_expr[edge] = JuMP.AffExpr(bg_load, tau[edge] => -Float64(bp.bin_capacity))
    end

    for b in bundle_idxs
        bundle = instance.bundles[b]
        for order in bundle.orders
            for arc in ttg.bundle_arcs[b]
                u_ttg, v_ttg = arc
                su = cache.ttg_spatial[u_ttg]
                sv = cache.ttg_spatial[v_ttg]
                su == sv && continue  # shortcut
                tsg_arc = cache.arc_of[(su, sv)]
                _bp_cost_of(tsg_arc.cost) === nothing && continue  # linear, no packing

                u_tsg = TPO.project_to_time_space_graph(u_ttg, order, instance)
                v_tsg = TPO.project_to_time_space_graph(v_ttg, order, instance)
                edge = (u_tsg, v_tsg)
                haskey(pack_expr, edge) || continue
                JuMP.add_to_expression!(pack_expr[edge], x[(b, arc)], order.total_size)
            end
        end
    end

    for (edge, expr) in pack_expr
        JuMP.@constraint(model, expr <= 0)
    end

    # ── Elementarity constraints ──
    # Each bundle visits each intermediate node (platform/port) at most once
    for b in bundle_idxs
        node_expr = Dict{String,JuMP.AffExpr}()
        ng = instance.network_graph.graph
        for arc in ttg.bundle_arcs[b]
            u_ttg, v_ttg = arc
            sv = cache.ttg_spatial[v_ttg]
            dst_node = ng[MetaGraphsNext.label_for(ng, sv)]
            if dst_node.node_type == :other  # intermediate nodes (platforms, ports)
                node_id = dst_node.id
                expr = get!(node_expr, node_id, JuMP.AffExpr(0.0))
                JuMP.add_to_expression!(expr, 1.0, x[(b, arc)])
            end
        end
        for (nid, expr) in node_expr
            JuMP.@constraint(model, expr <= 1)
        end
    end

    # ── Objective ──
    obj = JuMP.AffExpr()

    # Cost per truck on common TSG arcs: tau * cost_per_bin * scaling
    for edge in common_arcs
        bp = arc_bp[edge]
        u_tsg, v_tsg = edge
        su = cache.tsg_spatial[u_tsg]
        sv = cache.tsg_spatial[v_tsg]
        scaling = get(ttg.cost_scaling, (su, sv), 1.0)
        JuMP.add_to_expression!(obj, tau[edge], bp.cost_per_bin * scaling)
    end

    # Non-packing cost per bundle per arc
    for b in bundle_idxs
        for arc in ttg.bundle_arcs[b]
            u_ttg, v_ttg = arc
            arc_cost = _milp_arc_cost(instance, b, u_ttg, v_ttg)
            JuMP.add_to_expression!(obj, x[(b, arc)], arc_cost)
        end
    end

    JuMP.@objective(model, Min, obj)

    # Warm start for Gurobi (handles it well), skip for HiGHS (returns it unchanged)
    if use_gurobi
        for b in bundle_idxs
            path = sol.bundle_paths[b]
            isempty(path) && continue
            bundle = instance.bundles[b]
            origin = ttg.origin_codes[b]

            # Build shortcut adjacency to chain from origin to path[1]
            shortcut_next = Dict{Int,Int}()
            for arc in ttg.bundle_arcs[b]
                su = cache.ttg_spatial[arc[1]]
                sv = cache.ttg_spatial[arc[2]]
                if su == sv
                    shortcut_next[arc[1]] = arc[2]
                end
            end

            full_path_arcs = Set{Tuple{Int,Int}}()
            current = origin
            while current != path[1] && haskey(shortcut_next, current)
                next = shortcut_next[current]
                push!(full_path_arcs, (current, next))
                current = next
            end
            for k in 1:(length(path) - 1)
                push!(full_path_arcs, (path[k], path[k + 1]))
            end

            for arc in ttg.bundle_arcs[b]
                JuMP.set_start_value(x[(b, arc)], arc in full_path_arcs ? 1.0 : 0.0)
            end
        end

        # Warm start tau from current loads + selected bundles' contribution
        warm_tsg_loads = Dict{Tuple{Int,Int},Float64}()
        for edge in common_arcs
            warm_tsg_loads[edge] = get(loads, edge, 0.0)
        end
        for b in bundle_idxs
            path = sol.bundle_paths[b]
            isempty(path) && continue
            bundle = instance.bundles[b]
            for order in bundle.orders
                for k in 1:(length(path) - 1)
                    u_tsg = TPO.project_to_time_space_graph(path[k], order, instance)
                    v_tsg = TPO.project_to_time_space_graph(path[k + 1], order, instance)
                    edge = (u_tsg, v_tsg)
                    if haskey(warm_tsg_loads, edge)
                        warm_tsg_loads[edge] += order.total_size
                    end
                end
            end
        end
        for edge in common_arcs
            bp = arc_bp[edge]
            total_load = warm_tsg_loads[edge]
            JuMP.set_start_value(tau[edge], ceil(max(0.0, total_load) / bp.bin_capacity))
        end
    end

    # ── Solve ──
    start = time()
    JuMP.optimize!(model)

    if !JuMP.has_values(model)
        verbose && @info "MILP found no solution" elapsed = round(time() - start; digits=2)
        return nothing
    end

    if verbose
        obj_val = JuMP.objective_value(model)
        bound = JuMP.objective_bound(model)
        gap = abs(obj_val - bound) / max(abs(obj_val), 1e-10) * 100
        @info "MILP solved" elapsed = round(time() - start; digits=2) objective = round(
            obj_val; digits=2
        ) gap = round(gap; digits=3)
    end

    # ── Extract paths (shortcuts stripped, matching sol.bundle_paths format) ──
    paths = Vector{Vector{Int}}(undef, length(bundle_idxs))
    for (i, b) in enumerate(bundle_idxs)
        neighbors = Dict{Int,Int}()
        for arc in ttg.bundle_arcs[b]
            xval = JuMP.value(x[(b, arc)])
            su = cache.ttg_spatial[arc[1]]
            sv = cache.ttg_spatial[arc[2]]
            is_shortcut = (su == sv)
            if !is_shortcut && xval > 0.5
                neighbors[arc[1]] = arc[2]
            end
        end

        origin = ttg.origin_codes[b]
        destination = ttg.destination_codes[b]
        origin_spatial = cache.ttg_spatial[origin]

        # Find the real start node: first source of a non-shortcut arc
        # with the origin's spatial code (where shortcuts end)
        start_node = nothing
        for src in keys(neighbors)
            if cache.ttg_spatial[src] == origin_spatial
                start_node = src
                break
            end
        end

        if start_node === nothing
            paths[i] = copy(sol.bundle_paths[b])
            continue
        end

        path = [start_node]
        current = start_node
        max_steps = length(ttg.bundle_arcs[b]) + 1
        steps = 0
        while current != destination && steps < max_steps
            next = get(neighbors, current, nothing)
            next === nothing && break
            push!(path, next)
            current = next
            steps += 1
        end

        if current != destination
            paths[i] = copy(sol.bundle_paths[b])
        else
            paths[i] = path
        end
    end

    return paths
end

# ── Main perturbation dispatch ──

function TPO.perturbate!(
    sol::TPO.Solution,
    instance::TPO.Instance,
    p::MILPPlantPerturbation;
    rng::Random.AbstractRNG=Random.default_rng(),
    verbose::Bool=false,
)
    bundle_idxs = _select_bundles_by_plant(instance; rng, max_var=p.max_variables)
    isempty(bundle_idxs) && return (0.0, 0)

    all_common_arcs, arc_bp = _collect_common_tsg_arcs(instance)
    # Filter to TSG arcs reachable by selected bundles (drastically reduces tau variables)
    reachable = Set{Tuple{Int,Int}}()
    cache = instance.index_cache
    ttg = instance.travel_time_graph
    for b in bundle_idxs
        bundle = instance.bundles[b]
        for order in bundle.orders
            for arc in ttg.bundle_arcs[b]
                su = cache.ttg_spatial[arc[1]]
                sv = cache.ttg_spatial[arc[2]]
                su == sv && continue
                u_tsg = TPO.project_to_time_space_graph(arc[1], order, instance)
                v_tsg = TPO.project_to_time_space_graph(arc[2], order, instance)
                push!(reachable, (u_tsg, v_tsg))
            end
        end
    end
    common_arcs = filter(e -> e in reachable, all_common_arcs)
    loads = _compute_tsg_loads(sol, instance, bundle_idxs, common_arcs)
    old_paths = [copy(sol.bundle_paths[b]) for b in bundle_idxs]

    verbose &&
        @info "MILPPlantPerturbation" n_bundles = length(bundle_idxs) n_common_arcs = length(
            common_arcs
        ) n_total_common = length(all_common_arcs)

    new_paths = _solve_arc_flow_milp(
        instance,
        sol,
        bundle_idxs,
        common_arcs,
        arc_bp,
        loads;
        verbose,
        time_limit=15.0,
        optimizer_factory=p.optimizer_factory,
    )
    new_paths === nothing && return (0.0, 0)

    changed_mask = [new_paths[i] != old_paths[i] for i in eachindex(bundle_idxs)]
    !any(changed_mask) && return (0.0, 0)

    before = TPO.cost(sol)
    snap = TPO.snapshot_solution(sol, instance)

    # Remove and reinsert changed bundles
    changed_idxs = findall(changed_mask)
    for ci in changed_idxs
        b = bundle_idxs[ci]
        isempty(sol.bundle_paths[b]) && continue
        TPO.remove_bundle_path!(sol, instance, b)
    end
    for ci in changed_idxs
        b = bundle_idxs[ci]
        TPO.add_bundle_path!(sol, instance, b, new_paths[ci])
    end

    after = TPO.cost(sol)

    if after > before * 1.015
        TPO.restore_solution!(sol, snap, instance)
        verbose && @info "MILP perturbation reverted" before after delta = after - before
        return (0.0, 0)
    end

    improvement = before - after
    n_changed = sum(changed_mask)
    verbose && @info "MILP perturbation accepted" improvement n_changed
    return (improvement, n_changed)
end

export InboundNodeInfo,
    InboundArcInfo,
    InboundCommodityInfo,
    CarbonArcCost,
    StockArcCost,
    NodeVolumeCost,
    parse_inbound_instance,
    PlantPerturbation,
    SupplierPerturbation,
    MILPPlantPerturbation,
    NODE_ID,
    NODE_COST,
    NODE_CAPACITY,
    NODE_TYPE,
    ARC_ORIGIN_ID,
    ARC_DESTINATION_ID,
    ARC_SHIPMENT_COST,
    ARC_CAPACITY,
    ARC_TYPE,
    COMMODITY_ORIGIN_ID,
    COMMODITY_DESTINATION_ID,
    COMMODITY_SIZE,
    COMMODITY_ARRIVAL_DATE,
    COMMODITY_MAX_DELIVERY_TIME,
    COMMODITY_QUANTITY,
    COMMODITY_LEAD_TIME_COST

end  # module Inbound
