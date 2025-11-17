const NODE_ID = :point_account
const NODE_COST = :point_m3_cost
const NODE_CAPACITY = :point_m3_capacity
const NODE_TYPE = :point_type

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
            cost=row[NODE_COST],
            capacity=Int(row[NODE_CAPACITY]),
            info=InboundNodeInfo(Symbol(row[NODE_TYPE])),
        )
    end

    raw_arcs = map(eachrow(df_legs)) do row
        cost = if row.is_linear
            LinearArcCost(row.shipment_cost)
        else
            BinPackingArcCost(row.shipment_cost, row.capacity)
        end
        return NetworkArc(;
            origin_id="$(row.src_account)",
            destination_id="$(row.dst_account)",
            cost=cost,
        )
    end
    typeof(raw_arcs)
    arcs = collect_arcs((LinearArcCost, BinPackingArcCost), raw_arcs)

    commodities = map(eachrow(df_commodities)) do row
        Commodity(;
            origin_id="$(row.supplier_account)",
            destination_id="$(row.customer_account)",
            size=row.volume,
            arrival_date=DateTime(row.delivery_date, "yyyy-mm-dd HH:MM:SS+00:00"),
            info=InboundCommodityInfo(row.max_delivery_time),
        )
    end

    println("Number of nodes: ", length(nodes))
    println("Number of arcs: ", length(arcs))
    println("Number of commodities: ", length(commodities))

    return (; nodes, arcs, commodities)
end

struct InboundNodeInfo
    node_type::Symbol
end

struct InboundCommodityInfo
    max_delivery_time::Int
end
