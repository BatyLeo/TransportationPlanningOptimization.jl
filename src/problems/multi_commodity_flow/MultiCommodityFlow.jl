"""
`MultiCommodityFlow` gives access to public benchmark instances for multicommodity flow
problems, currently the Canad C instances, which carry, for each arc, a variable
cost, a capacity and a fixed cost.
They are loaded as the Unsplittable Multicommodity Flow Problem (UMCF) by default, or
as the Multicommodity Flow Network Design Problem (MCFND) with `network_design=true`.
Instances are downloaded and parsed on demand from the CommaLab collection via
DataDeps.jl.
"""
module MultiCommodityFlow

using DataDeps: DataDep, register, unpack, @datadep_str
using Dates: DateTime, Day
using DocStringExtensions: TYPEDEF, TYPEDSIGNATURES
using ...TransportationPlanningOptimization:
    NetworkNode, Arc, LinearArcCost, BinPackingArcCost, Commodity, Instance
using ..Problems: AbstractDataset
import ..Problems: list_instances, dataset_dir, load_instance

export CanadC, list_instances, load_instance

public parse_canad_instance, dataset_dir, datasets

include("datasets.jl")
include("parser.jl")

end
