module Outbound

using CSV
using DataFrames
using Dates
using Statistics
using TransportationPlanningOptimization

include("outbound_parser.jl")

const NODE_ID = :indice
const NODE_BTS_CANDIDATES = :ListeCandidatStockBTS
const NODE_TYPE = :TypeNode

const ARC_ORIGIN_ID = :origine
const ARC_DESTINATION_ID = :destination
const ARC_COST = :Cost
const ARC_TYPE = :TypeLeg
const ARC_CAPACITY = :VolMax

const COMMODITY_ORIGIN_ID = :usine
const COMMODITY_DESTINATION_ID = :destinationFinale
const COMMODITY_QUANTITY = :volumeSemaine
const COMMODITY_YEAR = :annee
const COMMODITY_WEEK = :semaine
const COMMODITY_MODEL = :model
const COMMODITY_TYPE_BT = :typeBT

const MODEL_INDEX = :indice
const MODEL_NAME = :modelName

const LOAD_FACTOR_MODEL = :Model_synthetic_code
const LOAD_FACTOR_VALUE = :load_factor_min_estimated

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
const MVP_NODE_RAIL = :rail_connection        # "Y" / "N"
const MVP_NODE_CAPA = :capa_max_transit

const MVP_VOL_ORIGIN = :route_origin_node
const MVP_VOL_DEST = :route_destination_node
const MVP_VOL_MODEL = :model_synthetic_code
const MVP_VOL_QTY = :volume
const MVP_VOL_YEAR = :manuf_date_TCM_year
const MVP_VOL_WEEK = :manuf_date_TCM_week
const MVP_VOL_BTS = :type_volume              # "BTS" / "No-Stock"

function preprocessing_outbound_data(raw_data_file, output_data_dir; overwrite=false)
    if !overwrite && isdir(output_data_dir)
        println("Parsed data directory already exists. Skipping preprocessing.")
        return nothing
    end
    raw_data = parse_outbound_file(raw_data_file)
    export_parsed_data(raw_data, output_data_dir)
    return nothing
end

function parse_load_factor_file(load_factor_file)
    load_factor_by_model = Dict{String,Float64}()
    @assert isfile(load_factor_file) "Expected load-factor file at $load_factor_file but it was not found."
    df_lf = DataFrame(CSV.File(load_factor_file))
    g = groupby(df_lf, LOAD_FACTOR_MODEL)
    for sub in g
        m = string(first(sub[!, LOAD_FACTOR_MODEL]))
        vals = collect(skipmissing(sub[!, LOAD_FACTOR_VALUE]))
        numvals = Float64[]
        for v in vals
            try
                push!(numvals, Float64(v))
            catch
                @warn "Could not convert load factor value $v for model $m; skipping it."
            end
        end
        if !isempty(numvals)
            load_factor_by_model[m] = minimum(numvals)
        end
    end
    return load_factor_by_model
end

function parse_outbound_instance(
    node_file,
    leg_file,
    commodity_file,
    model_file,
    load_factor_file;
    max_delivery_time=Day(365),
    all_linear=false,
)
    df_nodes = DataFrame(CSV.File(node_file))
    df_legs = DataFrame(CSV.File(leg_file))
    df_commodities = DataFrame(CSV.File(commodity_file))
    df_model = DataFrame(CSV.File(model_file))

    # filter out commodities with missing or non-positive size
    df_commodities = filter(
        row -> !ismissing(row[COMMODITY_QUANTITY]) && row[COMMODITY_QUANTITY] > 0,
        df_commodities,
    )

    nodes = map(eachrow(df_nodes)) do row
        bts_candidates = if ismissing(row[NODE_BTS_CANDIDATES])
            Int[]
        else
            parse.(Int, split(row[NODE_BTS_CANDIDATES], ";")[1:(end - 1)])
        end
        node_type_symbol = if row[NODE_TYPE] == "PC"
            :origin
        elseif row[NODE_TYPE] == "ZG"
            :destination
        else
            :other
        end

        NetworkNode(;
            id="$(row[NODE_ID])",
            node_type=node_type_symbol,
            info=OutboundNodeInfo(Symbol(row[NODE_TYPE]), bts_candidates),
        )
    end

    raw_arcs = map(eachrow(df_legs)) do row
        arc_type = Symbol(row[ARC_TYPE])

        # Route arcs have bin packing costs, others have linear costs
        cost = if arc_type == :R && !all_linear
            BinPackingArcCost(row[ARC_COST], 1.0)
        else
            LinearArcCost(row[ARC_COST])
        end

        Arc(;
            origin_id="$(row[ARC_ORIGIN_ID])",
            destination_id="$(row[ARC_DESTINATION_ID])",
            cost=cost,
            travel_time=Week(0),
            capacity=row[ARC_CAPACITY],
            info=OutboundArcInfo(arc_type),
        )
    end

    # Keep only the first arc for each (origin_id, destination_id) pair
    seen = Set{Tuple{String,String}}()
    duplicates = 0
    raw_arcs = filter(arc -> begin
        pair = (arc.origin_id, arc.destination_id)
        if pair in seen
            # TODO: build an arc type that can manage both F and R in a single arc
            duplicates += 1
            false
        else
            push!(seen, pair)
            true
        end
    end, raw_arcs)
    @warn "$duplicates duplicate arcs found; only the first occurrence for each (origin, destination) pair is kept."

    model_mapping = Dict{Int,String}(
        row[MODEL_INDEX] => string(row[MODEL_NAME]) for
        row in eachrow(df_model) if row[MODEL_INDEX] > 0
    )
    load_factor_by_model = parse_load_factor_file(load_factor_file)
    # Size, assuming a truck is of size 1
    size_by_model = Dict{Int,Float64}()
    for (idx, mname) in model_mapping
        @assert haskey(load_factor_by_model, mname) "No load factor found for model name $mname"
        lf_val = load_factor_by_model[mname]
        size_by_model[idx] = 1 / lf_val
    end

    commodities = map(eachrow(df_commodities)) do row
        year = row[COMMODITY_YEAR]
        week = row[COMMODITY_WEEK]
        @assert !ismissing(year) && !ismissing(week) "Year and week must be specified in commodity data."
        january_4 = Dates.Date(year, 1, 4)
        monday_week_1 = january_4 - Day(dayofweek(january_4) - 1) # Monday of ISO week 1
        date = DateTime(monday_week_1 + Week(week - 1))

        forbidden_arcs = Tuple{String,String}[]
        # # If BTS commodity, forbid arcs leading to ZG nodes that do not come from BTS list
        # if row[COMMODITY_TYPE_BT] == "BTS"
        #     dest_node_id = string(row[COMMODITY_DESTINATION_ID])
        #     dest_node = findfirst(n -> n.id == dest_node_id, nodes)
        #     @assert dest_node !== nothing "Destination node $dest_node_id not found among parsed nodes."
        #     bts_list = nodes[dest_node].info.bts_list
        #     for arc in raw_arcs
        #         if arc.destination_id == dest_node_id
        #             if !(arc.origin_id in bts_list)
        #                 push!(forbidden_arcs, (arc.origin_id, arc.destination_id))
        #             end
        #         end
        #     end
        # end

        Commodity(;
            origin_id="$(row[COMMODITY_ORIGIN_ID])",
            destination_id="$(row[COMMODITY_DESTINATION_ID])",
            quantity=Int(row[COMMODITY_QUANTITY]),
            size=size_by_model[row[COMMODITY_MODEL]],
            max_delivery_time=max_delivery_time,
            departure_date=date,
            forbidden_arcs=forbidden_arcs,
            info=OutBoundCommodityInfo(
                row[COMMODITY_MODEL], row[COMMODITY_TYPE_BT] == "BTS"
            ),
        )
    end

    return (; nodes, arcs=raw_arcs, commodities)
end

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

    df_nodes = DataFrame(CSV.File(nodes_file; delim=';'))
    df_legs = DataFrame(CSV.File(legs_file; delim=';'))
    df_volumes = DataFrame(CSV.File(volumes_file; delim=';'))

    nodes = map(eachrow(df_nodes)) do row
        node_type_symbol = if row[MVP_NODE_TYPE] == "Plant Compound"
            :origin
        elseif row[MVP_NODE_TYPE] == "Dealer Area"
            :destination
        else
            :other
        end
        NetworkNode(;
            id=String(row[MVP_NODE_CODE]),
            node_type=node_type_symbol,
            info=OutboundNodeInfo(Symbol(row[MVP_NODE_TYPE]), Int[]),
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

        Commodity(;
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
            @NamedTuple{capacity::Int, costs::Dict{String,Float64}}
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
            Arc(;
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
        Arc(;
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
    bts_list::Vector{Int}
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

export preprocessing_outbound_data,
    parse_outbound_instance, OutboundNodeInfo, OutBoundCommodityInfo, ModelLinearArcCost

end # module Outbound
