"""
    Inbound

Test helper module for reading and parsing inbound instances from CSV files.
Contains constants for column mappings and functions for loading test data.
"""
module Inbound

using CSV
using DataFrames
using Dates
using NetworkDesignOptimization

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
const COMMODITY_SIZE = :volume
const COMMODITY_ARRIVAL_DATE = :delivery_date
const COMMODITY_MAX_DELIVERY_TIME = :max_delivery_time
const COMMODITY_QUANTITY = :quantity

"""
    InboundNodeInfo

Test data structure for node metadata in inbound instances.
"""
struct InboundNodeInfo
    node_type::Symbol
end

"""
    InboundArcInfo

Test data structure for arc metadata in inbound instances.
"""
struct InboundArcInfo
    arc_type::Symbol
end

"""
    InboundCommodityInfo

Test data structure for commodity metadata in inbound instances.
"""
struct InboundCommodityInfo end

"""
    read_inbound_instance(node_file::String, leg_file::String, commodity_file::String)

Read an inbound instance from three CSV files: nodes, legs, and commodities.

Returns a named tuple `(; nodes, arcs, commodities)` containing:
- `nodes::Vector{NetworkNode}` - Network nodes parsed from node_file
- `arcs::Vector{NetworkArc}` - Network arcs parsed from leg_file
- `commodities::Vector{Commodity}` - Commodities parsed from commodity_file

The function performs deduplication of arcs (keeps only the first arc for each 
origin-destination pair) and handles heterogeneous cost function types.
"""
function read_inbound_instance(node_file::String, leg_file::String, commmodity_file::String)
    df_nodes = DataFrame(CSV.File(node_file))
    df_legs = DataFrame(CSV.File(leg_file))
    df_commodities = DataFrame(CSV.File(commmodity_file))

    nodes = map(eachrow(df_nodes)) do row
        NetworkNode(;
            id="$(row[NODE_ID])",
            cost=row[NODE_COST],
            capacity=Int(row[NODE_CAPACITY]),
            info=InboundNodeInfo(Symbol(row[NODE_TYPE])),
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
        cost = if row.is_linear
            LinearArcCost(row[ARC_SHIPMENT_COST])
        else
            BinPackingArcCost(row[ARC_SHIPMENT_COST], row[ARC_CAPACITY])
        end
        return NetworkArc(;
            origin_id="$(row[ARC_ORIGIN_ID])",
            destination_id="$(row[ARC_DESTINATION_ID])",
            cost=cost,
            info=InboundArcInfo(Symbol(row[ARC_TYPE])),
        )
    end
    # keep only the first arc for each (origin_id, destination_id) pair
    seen = Set{Tuple{String,String}}()
    raw_arcs = filter(arc -> begin
        pair = (arc.origin_id, arc.destination_id)
        if pair in seen
            false
        else
            push!(seen, pair)
            true
        end
    end, raw_arcs)
    # filter!(arc -> arc.info.arc_type in ALLOWED_ARC_TYPES, raw_arcs)
    arcs = collect_arcs((LinearArcCost, BinPackingArcCost), raw_arcs)

    commodities = map(eachrow(df_commodities)) do row
        Commodity(;
            origin_id="$(row[COMMODITY_ORIGIN_ID])",
            destination_id="$(row[COMMODITY_DESTINATION_ID])",
            size=row[COMMODITY_SIZE],
            quantity=Int(row[COMMODITY_QUANTITY]),
            arrival_date=DateTime(row[COMMODITY_ARRIVAL_DATE], "yyyy-mm-dd HH:MM:SS+00:00"),
            max_delivery_time=Week(row[COMMODITY_MAX_DELIVERY_TIME]),
        )
    end

    return (; nodes, arcs, commodities)
end

export InboundNodeInfo,
    InboundArcInfo,
    InboundCommodityInfo,
    read_inbound_instance,
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
    COMMODITY_QUANTITY

end  # module Inbound
