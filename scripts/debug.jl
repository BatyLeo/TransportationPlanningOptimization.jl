using NetworkDesignOptimization

instance = "tiny"
datadir = joinpath(@__DIR__, "..", "data")
nodes_file = joinpath(datadir, "$(instance)_nodes.csv")
legs_file = joinpath(datadir, "$(instance)_legs.csv")
commodities_file = joinpath(datadir, "$(instance)_commodities.csv")

commodity_data = read_inbound_instance(nodes_file, legs_file, commodities_file)

res = Dict()
for comm in commodity_data
    (; volume, delivery_time_step, max_delivery_time, origin_account, destination_account) =
        comm
    res[origin_account, destination_account, delivery_time_step] = comm
end
res

map(res) do ((o, d, t), comm)
    println("Origin: $o, Destination: $d, Time: $t, Volume: $(comm.volume)")
end
