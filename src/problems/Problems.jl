"""
`Problems` gathers the representative transportation planning problems.

Each problem module builds on the package public API.
Dataset-backed modules implement the [`AbstractDataset`](@ref) interface, and modules with
a reference solver also implement [`benchmark_solve`](@ref).
"""
module Problems

using DocStringExtensions: TYPEDEF

"""
$TYPEDEF

Common interface for a dataset of benchmark instances, see [`list_instances`](@ref),
[`dataset_dir`](@ref) and [`load_instance`](@ref).
Each problem module also provides a public, non-exported `datasets()` function listing
its datasets, so callers can sweep over every instance with
`for ds in SomeProblem.datasets(), name in list_instances(ds)`.
"""
abstract type AbstractDataset end

"""
    list_instances(ds)

Return the names of the instances available in dataset `ds`.
"""
function list_instances end

"""
    dataset_dir(ds)

Return the local directory holding the files of dataset `ds`, downloading them if needed.
"""
function dataset_dir end

"""
    load_instance(ds, name; kwargs...)

Load instance `name` from dataset `ds` and return it as an `Instance`.
Dataset-specific keywords select problem variants.
"""
function load_instance end

"""
    benchmark_solve(ds, name; kwargs...)

Solve instance `name` of dataset `ds` with the problem's reference solver.

Returns a `NamedTuple` with fields:
- `solution`: a `Solution` of `instance`, or `nothing` if no solution was found
- `instance`: the `Instance` the solution belongs to
- `objective_value`, `objective_bound`, `relative_gap`, `termination_status`, `solve_time`
"""
function benchmark_solve end

include("inbound/Inbound.jl")
include("multi_commodity_flow/MultiCommodityFlow.jl")

public AbstractDataset, list_instances, dataset_dir, load_instance, benchmark_solve
public Inbound, MultiCommodityFlow

end
