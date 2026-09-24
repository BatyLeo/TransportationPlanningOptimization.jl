"""
`Inbound` reads and parses inbound transportation instances from CSV files.
Contains constants for column mappings and functions for loading instance data.
"""
module Inbound

using CSV: CSV
using DataFrames: DataFrame
using Dates: DateTime, Week
using ...TransportationPlanningOptimization:
    TransportationPlanningOptimization,
    NetworkNode,
    LinearNodeCost,
    Arc,
    LinearArcCost,
    BinPackingArcCost,
    Commodity,
    AbstractArcCostFunction,
    LightCommodity,
    evaluate

const TPO = TransportationPlanningOptimization

export InboundArcInfo, InboundCommodityInfo, StockArcCost, parse_inbound_instance

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

# Integer scaling factor for commodity sizes and arc capacities
const VOLUME_FACTOR = 100

"""
    InboundArcInfo

Inbound arc metadata, carrying the leg type read from the `leg_type` column
of the legs CSV.
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
    StockArcCost(distance)

Stock cost on an arc, computed as `distance * sum(stockCost)` over orders.
The arc's distance (km) comes from the leg CSV and per-commodity stock cost
is read from `commodity.info.stock_cost`.

Requires `Commodity.info` to be an `InboundCommodityInfo` (or any struct
exposing `stock_cost`). Calling `evaluate` on commodities without that field
errors at the property access.
"""
struct StockArcCost <: AbstractArcCostFunction
    distance::Float64
end

function TPO.evaluate(
    c::StockArcCost, comms::Vector{<:LightCommodity}; presorted::Bool=false
)
    return c.distance * sum(x.info.stock_cost for x in comms; init=0.0)
end

include("parser.jl")

end
