module NetworkDesignOptimization

import CSV
using DataFrames: DataFrame, names
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES

include("commodity.jl")
include("order.jl")
include("network_node.jl")
include("network_arc.jl")
include("bundle.jl")
include("instance.jl")

include("parsing/parser.jl")
include("parsing/commodity.jl")

export FullCommodity
export Instance, Bundle, Order, Commodity, NetworkNode, NetworkArc
export read_inbound_instance

end
