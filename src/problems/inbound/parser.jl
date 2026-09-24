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
function parse_inbound_instance(node_file::String, leg_file::String, commodity_file::String)
    df_nodes = DataFrame(CSV.File(node_file; stringtype=String))
    df_legs = DataFrame(CSV.File(leg_file; stringtype=String))
    df_commodities = DataFrame(CSV.File(commodity_file; stringtype=String))

    nodes = map(eachrow(df_nodes)) do row
        node_type_symbol = if row[NODE_TYPE] == "supplier"
            :origin
        elseif row[NODE_TYPE] == "plant"
            :destination
        else
            :other
        end

        return NetworkNode(;
            id=string(row[NODE_ID]),
            node_type=node_type_symbol,
            capacity=Int(row[NODE_CAPACITY]),
            node_cost=LinearNodeCost(Float64(row[NODE_COST]) / VOLUME_FACTOR),
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
            base_cost, LinearArcCost(carbon_cost / capacity), StockArcCost(distance)
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
        return Commodity(;
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
