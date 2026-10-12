module Outbound

using CSV
using DataFrames
using Dates
using TransportationPlanningOptimization

# --- dataMVP schema column names ---
const MVP_LEG_ORIGIN = :departure_node_code
const MVP_LEG_DEST = :arrival_node_code
const MVP_LEG_MODE = :mode_transport          # values: "F" (rail), "R" (road), ...
const MVP_LEG_MIN_VOL = :transport_min_volume_veh_sem
const MVP_LEG_MAX_VOL = :transport_max_capacity_veh_sem
const MVP_LEG_COST = :total_cost_vehicle
const MVP_LEG_MODEL = :model_synthetic_code   # per-vehicle cost varies by this

const MVP_NODE_CODE = :node_code
const MVP_NODE_TYPE = :type_node
const MVP_NODE_INTERMEDIATE = :CI_intermediate_compound  # "Y" / "N"
const MVP_NODE_RAIL = :rail_connection        # "Y" / "N"
const MVP_NODE_CAPA = :capa_max_transit

const MVP_VOL_ORIGIN = :route_origin_node
const MVP_VOL_DEST = :route_destination_node
const MVP_VOL_MODEL = :model_synthetic_code
const MVP_VOL_QTY = :volume
const MVP_VOL_YEAR = :manuf_date_TCM_year
const MVP_VOL_WEEK = :manuf_date_TCM_week
const MVP_VOL_BTS = :type_volume              # "BTS" / "No-Stock"

"""
    parse_dataMVP_instance(data_dir::AbstractString; max_delivery_time=Day(365), all_linear=false)

Read the `dataMVP` outbound format (5 CSV files in `data_dir/input/`) and return
a NamedTuple `(; nodes, arcs, commodities)` ready to feed `TPO.Instance(...)`.

Multi-modal legs (e.g. truck and rail on the same origin/destination pair)
appear in `arcs` as duplicate parsing-stage `Arc` values with different
`info.mode`. Pass `allow_multimodal=true` to `Instance(...)` (or `build_instance`)
to auto-promote them into a `MultiModalArc`.
"""
function parse_dataMVP_instance(
    data_dir::AbstractString;
    max_delivery_time=Day(365),
    all_linear=false,
    keep_modes::Bool=true,
    model_costs::Bool=false,
)
    nodes_file = joinpath(data_dir, "input", "nodes_input_algo.csv")
    legs_file = joinpath(data_dir, "input", "leg_input_algo.csv")
    volumes_file = joinpath(data_dir, "input", "volumes_input_algo.csv")

    df_nodes = DataFrame(CSV.File(nodes_file; delim=(';')))
    df_legs = DataFrame(CSV.File(legs_file; delim=(';')))
    df_volumes = DataFrame(CSV.File(volumes_file; delim=(';')))

    nodes = map(eachrow(df_nodes)) do row
        # Plant compound CLSI NOVO and dealer areas are `N`, the other plant compounds, compounds and ports are `Y`.
        return Node(;
            id=String(row[MVP_NODE_CODE]),
            transit=row[MVP_NODE_INTERMEDIATE] == "Y",
            info=OutboundNodeInfo(Symbol(row[MVP_NODE_TYPE])),
        )
    end

    df_volumes = filter(
        row -> !ismissing(row[MVP_VOL_QTY]) && row[MVP_VOL_QTY] > 0, df_volumes
    )

    commodities = map(eachrow(df_volumes)) do row
        year = row[MVP_VOL_YEAR]
        week = row[MVP_VOL_WEEK]
        january_4 = Dates.Date(year, 1, 4)
        monday_week_1 = january_4 - Day(dayofweek(january_4) - 1)
        date = DateTime(monday_week_1 + Week(week - 1))

        return Commodity(;
            origin_id=String(row[MVP_VOL_ORIGIN]),
            destination_id=String(row[MVP_VOL_DEST]),
            quantity=Int(ceil(row[MVP_VOL_QTY])),
            size=1.0,  # MVP: assume one truck/rail unit per vehicle until load-factor data lands
            max_delivery_time=max_delivery_time,
            departure_date=date,
            forbidden_arcs=Tuple{String,String}[],
            info=OutBoundCommodityInfo(row[MVP_VOL_MODEL], row[MVP_VOL_BTS] == "BTS"),
        )
    end

    # Per-model exact costs: the leg CSV is denormalized over
    # `model_synthetic_code` (the per-vehicle cost differs by model, e.g. BJA vs
    # 1325 on the same road leg). Instead of collapsing to one scalar, aggregate
    # every model's cost into a `ModelLinearArcCost` so each commodity is costed
    # by its own model (matching the reference Hexaly solution exactly).
    if model_costs
        grouped = Dict{
            Tuple{String,String,Symbol},
            @NamedTuple{capacity::Int,costs::Dict{String,Float64}}
        }()
        arc_order = Tuple{String,String,Symbol}[]
        for row in eachrow(df_legs)
            mode_sym = Symbol(row[MVP_LEG_MODE])
            key = (String(row[MVP_LEG_ORIGIN]), String(row[MVP_LEG_DEST]), mode_sym)
            if !haskey(grouped, key)
                grouped[key] = (
                    capacity=Int(ceil(row[MVP_LEG_MAX_VOL])), costs=Dict{String,Float64}()
                )
                push!(arc_order, key)
            end
            # keep the first cost seen per model for this (origin, destination, mode)
            get!(grouped[key].costs, string(row[MVP_LEG_MODEL]), Float64(row[MVP_LEG_COST]))
        end
        arcs = map(arc_order) do key
            (origin_id, destination_id, mode_sym) = key
            g = grouped[key]
            return Arc(;
                origin_id=origin_id,
                destination_id=destination_id,
                cost=ModelLinearArcCost(g.costs),
                travel_time=Week(0),
                capacity=g.capacity,
                info=OutboundArcInfo(mode_sym),
            )
        end
        return (; nodes, arcs, commodities)
    end

    # Build one parsing-stage Arc per leg row. Multi-modal legs (same
    # (origin, destination), different `mode_transport`) are preserved as
    # separate Arcs so the framework can promote them via
    # `allow_multimodal=true` in `Instance(...)`. The CSV is denormalized
    # (e.g. one row per `category_model`), so we keep only the first
    # occurrence per `(origin, destination, mode)` triple.
    raw_arcs = map(eachrow(df_legs)) do row
        mode_sym = Symbol(row[MVP_LEG_MODE])  # :F (rail), :M (sea) or :R (road)
        capacity = Int(ceil(row[MVP_LEG_MAX_VOL]))
        unit_cost = row[MVP_LEG_COST]
        cost = if mode_sym == :R && !all_linear
            BinPackingArcCost(unit_cost, 1.0)
        else
            LinearArcCost(unit_cost)
        end
        return Arc(;
            origin_id=String(row[MVP_LEG_ORIGIN]),
            destination_id=String(row[MVP_LEG_DEST]),
            cost=cost,
            travel_time=Week(0),
            capacity=capacity,
            info=OutboundArcInfo(mode_sym),
        )
    end

    seen = Set{Tuple{String,String,Symbol}}()
    duplicates = 0
    arcs = filter(raw_arcs) do a
        key = if keep_modes
            (a.origin_id, a.destination_id, a.info.arc_type)
        else
            (a.origin_id, a.destination_id, :_)
        end
        if key in seen
            duplicates += 1
            false
        else
            push!(seen, key)
            true
        end
    end
    if duplicates > 0
        @warn "$duplicates duplicate Arc rows dropped; only the first occurrence per " *
            (
                if keep_modes
                    "(origin, destination, mode) triple"
                else
                    "(origin, destination) pair"
                end
            ) *
            " is kept."
    end

    return (; nodes, arcs, commodities)
end

struct OutboundNodeInfo
    type_node::Symbol
end

struct OutboundArcInfo
    arc_type::Symbol
end

struct OutBoundCommodityInfo{T}
    model::T
    is_BTS::Bool
end

"""
A linear arc cost whose unit cost depends on the commodity's model.

`cost_per_model` maps a `model_synthetic_code` (as a `String`) to its per-vehicle
cost on this arc. Each commodity is costed by its own model, so for linear costs
with a single time step the total equals `sum(cost_per_model[model] * size)`. This
avoids the denormalization collapse of `LinearArcCost` (which keeps a single,
arbitrary first-occurrence cost per arc) and reproduces the reference solver's
per-vehicle accounting exactly.
"""
struct ModelLinearArcCost <: TransportationPlanningOptimization.AbstractArcCostFunction
    cost_per_model::Dict{String,Float64}
end

function TransportationPlanningOptimization.evaluate(
    arc_f::ModelLinearArcCost,
    commodities::Vector{<:TransportationPlanningOptimization.LightCommodity};
    presorted::Bool=false,
)
    total = 0.0
    for c in commodities
        total += arc_f.cost_per_model[string(c.info.model)] * c.size
    end
    return total
end

# Closed form for greedy/local-search hot path (mirrors the LinearArcCost
# specialization): the marginal cost only depends on the new commodities.
function TransportationPlanningOptimization.incremental_cost(
    arc_f::ModelLinearArcCost, ::Vector{C}, new_commodities::Vector{C}
) where {C<:TransportationPlanningOptimization.LightCommodity}
    total = 0.0
    for c in new_commodities
        total += arc_f.cost_per_model[string(c.info.model)] * c.size
    end
    return total
end

export parse_dataMVP_instance, OutboundNodeInfo, OutBoundCommodityInfo, ModelLinearArcCost

end # module Outbound
