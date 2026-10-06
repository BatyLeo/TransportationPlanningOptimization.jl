"""
`MultiCommodityFlow` gives access to public benchmark instances for multicommodity flow
problems, currently the Canad C instances.

Instances load as the Unsplittable Multicommodity Flow Problem (UMCF) by default, or as
the Multicommodity Flow Network Design Problem (MCFND) with `network_design=true`.
[`benchmark_solve`](@ref) solves them exactly with JuMP (HiGHS by default).
"""
module MultiCommodityFlow

using DataDeps: DataDep, register, unpack, @datadep_str
using Dates: DateTime, Day
using DocStringExtensions: TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES
using JuMP:
    Model,
    @variable,
    @constraint,
    @expression,
    @objective,
    fix,
    optimize!,
    set_silent,
    set_time_limit_sec,
    primal_status,
    FEASIBLE_POINT,
    value,
    objective_bound,
    termination_status,
    INFEASIBLE,
    INFEASIBLE_OR_UNBOUNDED,
    solve_time
using HiGHS: HiGHS
using ...TransportationPlanningOptimization:
    Node, Arc, LinearArcCost, BinPackingArcCost, Commodity, Instance, Solution, Leg, cost
using ..Problems: AbstractDataset
import ..Problems: list_instances, dataset_dir, load_instance, benchmark_solve

export CanadC, list_instances, load_instance, benchmark_solve

public parse_canad_instance, dataset_dir, datasets

include("datasets.jl")
include("data.jl")
include("parser.jl")
include("mip.jl")

end
