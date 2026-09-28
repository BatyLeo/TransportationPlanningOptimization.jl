"""
`MultiCommodityFlow` gives access to public benchmark instances for multicommodity flow
problems, currently the Canad C instances of the fixed-charge multicommodity
capacitated network design (MCND) problem.
Passing `fixed_costs=false` gives the unsplittable multicommodity flow (UMCF) version
of the same data.
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
