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
            node_cost=NodeVolumeCost(Float64(row[NODE_COST])),
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
        capacity = Int(row[ARC_CAPACITY])
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
            size=row[COMMODITY_SIZE],
            quantity=Int(row[COMMODITY_QUANTITY]),
            arrival_date=DateTime(row[COMMODITY_ARRIVAL_DATE], "yyyy-mm-dd HH:MM:SS+00:00"),
            max_delivery_time=Week(row[COMMODITY_MAX_DELIVERY_TIME]),
            info=InboundCommodityInfo(Float64(row[COMMODITY_LEAD_TIME_COST])),
        )
    end

    return (; nodes, arcs=raw_arcs, commodities)
end

export InboundNodeInfo,
    InboundArcInfo,
    InboundCommodityInfo,
    CarbonArcCost,
    StockArcCost,
    NodeVolumeCost,
    parse_inbound_instance,
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
