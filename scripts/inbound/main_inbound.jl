using CSV
using Dates
using DataFrames
using NetworkDesignOptimization
includet("Inbound.jl")

instance = "small"
datadir = joinpath(@__DIR__, "..", "..", "data", "inbound2")
nodes_file = joinpath(datadir, "$(instance)_nodes.csv")
legs_file = joinpath(datadir, "$(instance)_legs.csv")
commodities_file = joinpath(datadir, "$(instance)_commodities.csv")

(; nodes, arcs, commodities) = read_inbound_instance(
    nodes_file, legs_file, commodities_file
);

eltype(nodes)
eltype(arcs)
eltype(commodities)

using Graphs, MetaGraphsNext

function build_instance(
    nodes::Vector{<:NetworkNode},
    arcs::Vector{<:NetworkArc},
    commodities::Vector{Commodity{is_date_arrival,ID,I}},
) where {is_date_arrival,ID,I}
    # building the network graph
    network_graph = NetworkGraph(nodes, arcs)
    # wrapping commodities into light commodities
    full_commodities = LightCommodity{is_date_arrival,I}[]
    order_dict = Dict{Tuple{Int,String,String},Vector{LightCommodity{is_date_arrival,I}}}()

    # normalize all dates to Date so DateTime operands are handled consistently
    start_date = minimum(Date.([c.date for c in commodities]))
    for comm in commodities
        to_append = [
            LightCommodity{is_date_arrival,I}(
                comm.origin_id, comm.destination_id, comm.date, comm.size, comm.info
            ) for _ in 1:(comm.quantity)
        ]
        append!(full_commodities, to_append)
        # week index relative to the earliest arrival_date (discretize by 7-day weeks)
        week_idx = Int(div(Dates.value(Date(comm.date) - start_date), 7)) + 1
        if haskey(order_dict, (week_idx, comm.origin_id, comm.destination_id))
            append!(order_dict[(week_idx, comm.origin_id, comm.destination_id)], to_append)
        else
            order_dict[(week_idx, comm.origin_id, comm.destination_id)] = to_append
        end
    end
    orders = [
        Order{is_date_arrival,I}(
            order_dict[key],
            key[1],
            if is_date_arrival
                maximum(comm.date for comm in order_dict[key])
            else
                minimum(comm.date for comm in order_dict[key]) # TODO: check things out here
            end,
        ) for key in keys(order_dict)
    ]
    return network_graph, full_commodities, orders
end

network_graph, full_commodities, orders = build_instance(nodes, arcs, commodities);
network_graph
full_commodities
orders
# TODO: bundles
