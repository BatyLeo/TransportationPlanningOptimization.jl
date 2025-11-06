using CSV
using DataFrames

function read_outbound_instance(node_file, leg_file, commodity_file)
    df_nodes = DataFrame(CSV.File(node_file))
    df_legs = DataFrame(CSV.File(leg_file))
    df_commodities = DataFrame(CSV.File(commodity_file))
    println("Node columns: ", names(df_nodes))
    println("Legs columns: ", names(df_legs))
    println("Commodity columns: ", names(df_commodities))

    return (df_nodes, df_legs, df_commodities)
end

struct OutboundNodeInfo
    type_node::Symbol
    bts_list::Vector{Int}
end

struct OutBoundCommodityInfo
    model::Int
    is_BTS::Bool
end
