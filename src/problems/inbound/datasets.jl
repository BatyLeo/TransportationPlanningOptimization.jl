"""
$TYPEDEF

Nine Renault inbound instances, from the regional `small` to the worldwide `world5`,
stored as flat `<name>_{nodes,legs,commodities,routes}.csv` files.
Instances use weekly time steps and are loaded with [`load_instance`](@ref).
"""
struct RenaultInbound <: AbstractDataset end

datadep_name(::RenaultInbound) = "TransportationPlanningILSData"

"""
$TYPEDSIGNATURES

Return the datasets of the `Inbound` problem.
"""
datasets() = [RenaultInbound()]

"""
$TYPEDSIGNATURES

Return the local folder of dataset `d`, downloading the archive on first call.
"""
dataset_dir(d::RenaultInbound) = joinpath(@datadep_str(datadep_name(d)), "data")

"""
$TYPEDSIGNATURES

Sorted instance names available in dataset `d`.
"""
function list_instances(d::RenaultInbound)
    return sort([
        String(chopsuffix(f, "_nodes.csv")) for
        f in readdir(dataset_dir(d)) if endswith(f, "_nodes.csv")
    ])
end

"""
$TYPEDSIGNATURES

Load instance `name` from dataset `d` as an `Instance` with weekly time steps,
downloading it on first use.
`wrap_time` enables the cyclic weekly horizon.

By default (`dates_from_time_step=true`), the time model of the reference implementation
is reproduced: orders are keyed on the `delivery_time_step` column, which gives a
26-step cyclic horizon on `world2` to `world5`, where this column does not follow the
calendar.
This equivalence holds with the default `wrap_time=true` (the steps start at 0).
Both readings agree on `small` to `world`.
With `dates_from_time_step=false`, the real `delivery_date` is read instead.
"""
function load_instance(
    d::RenaultInbound,
    name::AbstractString;
    wrap_time::Bool=true,
    dates_from_time_step::Bool=true,
)
    dir = dataset_dir(d)
    (; nodes, arcs, commodities) = parse_inbound_instance(
        joinpath(dir, name * "_nodes.csv"),
        joinpath(dir, name * "_legs.csv"),
        joinpath(dir, name * "_commodities.csv");
        dates_from_time_step,
    )
    return Instance(nodes, arcs, commodities, Week(1); wrap_time)
end

const RENAULT_INBOUND_MESSAGE = "RenaultInbound: Worldwide-scale Shipper Transportation Planning Instances (Renault Group and CERMICS, Ecole des Ponts). Source: https://doi.org/10.5281/zenodo.17234091, license CC-BY-4.0. Please cite: \"Optimizing a Worldwide-scale Shipper Transportation Planning in a Carmaker Supply Chain\", arXiv 2509.07576."

function __init__()
    register(
        DataDep(
            datadep_name(RenaultInbound()),
            RENAULT_INBOUND_MESSAGE,
            "https://zenodo.org/records/17234091/files/TransportationPlanningILSData.zip?download=1",
            "b97da3e10201a905292f0b82e3121de52fbecc3e09da4ab315723a8ae5e4c33a";
            post_fetch_method=unpack,
        ),
    )
    return nothing
end
