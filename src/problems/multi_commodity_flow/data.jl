"""
$TYPEDEF

Problem-specific data for a Canad C multicommodity flow instance, as read from a `.dow`
file.

# Fields
$TYPEDFIELDS
"""
Base.@kwdef struct _MCFData
    "number of nodes, labelled `1:n_nodes`"
    n_nodes::Int
    "tail node of each arc"
    tails::Vector{Int}
    "head node of each arc"
    heads::Vector{Int}
    "per-unit variable routing cost of each arc"
    var_costs::Vector{Int}
    "capacity of each arc"
    capacities::Vector{Int}
    "fixed cost paid once per used arc (network design variant only)"
    fixed_costs::Vector{Int}
    "origin node of each commodity"
    origins::Vector{Int}
    "destination node of each commodity"
    destinations::Vector{Int}
    "demand (size) of each commodity"
    demands::Vector{Int}
    "whether the network design variant (arc fixed costs) is active"
    network_design::Bool = false
end
