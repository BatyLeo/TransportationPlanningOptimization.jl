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
            cost=0.0,
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

struct OutboundNodeInfo
    type_node::Symbol
    bts_list::Vector{Int}
end

struct OutboundArcInfo
    arc_type::Symbol
end

struct OutBoundCommodityInfo
    model::Int
    is_BTS::Bool
end

export preprocessing_outbound_data,
    parse_outbound_instance, OutboundNodeInfo, OutBoundCommodityInfo

end # module Outbound
