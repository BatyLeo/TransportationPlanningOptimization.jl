"""
`Problems` gathers the representative transportation planning problems.
Each problem module relies only on the package public API.
"""
module Problems

include("inbound/Inbound.jl")
include("multi_commodity_flow/MultiCommodityFlow.jl")

public Inbound, MultiCommodityFlow

end
