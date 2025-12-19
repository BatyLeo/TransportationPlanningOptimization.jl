const NODE_ID = :point_account
const NODE_COST = :point_m3_cost
const NODE_CAPACITY = :point_m3_capacity
const NODE_TYPE = :point_type

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

const COMMODITY_ORIGIN_ID = :supplier_account
const COMMODITY_DESTINATION_ID = :customer_account
const COMMODITY_SIZE = :volume
const COMMODITY_ARRIVAL_DATE = :delivery_date
const COMMODITY_MAX_DELIVERY_TIME = :max_delivery_time
const COMMODITY_QUANTITY = :quantity

"""
Read an inbound instance from three CSV files: nodes, legs, and commodities.
"""
function read_inbound_instance(node_file::String, leg_file::String, commmodity_file::String)
    df_nodes = DataFrame(CSV.File(node_file))
    df_legs = DataFrame(CSV.File(leg_file))
    df_commodities = DataFrame(CSV.File(commmodity_file))

    nodes = map(eachrow(df_nodes)) do row
        NetworkNode(;
            id="$(row[NODE_ID])",
            node_type=Symbol(row[NODE_TYPE]),
            cost=row[NODE_COST],
            capacity=Int(row[NODE_CAPACITY]),
            info=InboundNodeInfo(),
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

    println("Number of nodes: ", length(nodes))
    println("Number of arcs: ", length(arcs))
    println("Number of commodities: ", length(commodities))

    return (; nodes, arcs, commodities)
end

struct InboundNodeInfo end

struct InboundCommodityInfo end

struct InboundArcInfo
    arc_type::Symbol
end
