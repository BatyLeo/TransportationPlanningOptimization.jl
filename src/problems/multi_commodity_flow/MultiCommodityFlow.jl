"""
`MultiCommodityFlow` gives access to public benchmark instances for multicommodity flow
problems, currently the Canad C instances of the multicommodity capacitated fixed-charge
network design problem (solved here with unsplittable routing, and usable as unsplittable
multicommodity flow instances by ignoring fixed costs), downloaded on demand from the
CommaLab collection via DataDeps.jl.
"""
module MultiCommodityFlow

using DataDeps: DataDep, register, unpack, @datadep_str
using DocStringExtensions: TYPEDEF, TYPEDSIGNATURES

export CanadC, dataset_dir, list_instances

include("datasets.jl")

end
