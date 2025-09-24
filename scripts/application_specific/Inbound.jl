"""
$TYPEDSIGNATURES

Read an inbound instance from three CSV files: nodes, legs, and commodities.
"""
function read_inbound_instance(node_file::String, leg_file::String, commmodity_file::String)
    df_nodes = DataFrame(CSV.File(node_file))
    df_legs = DataFrame(CSV.File(leg_file))
    df_commodities = DataFrame(CSV.File(commmodity_file))
    println("Node columns: ", names(df_nodes))
    println("Legs columns: ", names(df_legs))
    println("Commodity columns: ", names(df_commodities))
    commodity_data = map(eachrow(df_commodities)) do row
        @info row.max_delivery_time
        FullCommodity(;
            origin_id=row.supplier_account,
            destination_id=row.customer_account,
            size=row.volume,
            delivery_time_step=row.delivery_time_step,
            max_delivery_time=row.max_delivery_time,
        )
    end
    println("Number of commodities: ", length(commodity_data))
    return commodity_data
end
