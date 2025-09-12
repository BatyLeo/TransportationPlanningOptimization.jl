struct Instance{I,J,K}
    bundles::Vector{Bundle{I,J}}
    network_graph::Any
    time_space_graph::Any
    travel_time_graph::Any
end
