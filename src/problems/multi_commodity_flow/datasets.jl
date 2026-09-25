"""
$TYPEDEF

31 Canad "C" instances of the multicommodity capacitated fixed-charge network design
problem, with arc variable cost, capacity and fixed cost, stored one `.dow` file per
instance.
"""
struct CanadC end

datadep_name(::CanadC) = "CommaLab_C"

"""
$TYPEDSIGNATURES

Return the local folder of collection `c`, downloading the archive on first call.
"""
dataset_dir(c::CanadC) = @datadep_str(datadep_name(c))

"""
$TYPEDSIGNATURES

Sorted instance names (without extension) available in collection `c`.
"""
function list_instances(c::CanadC)
    return [first(splitext(f)) for f in readdir(dataset_dir(c)) if endswith(f, ".dow")]
end

const COMMALAB_PAGE = "https://commalab.di.unipi.it/datasets/mmcf/"

const CANADC_MESSAGE = "CanadC: 31 Canad \"C\" instances of the multicommodity capacitated fixed-charge network design problem. Source: $COMMALAB_PAGE. Please cite: T.G. Crainic, A. Frangioni, B. Gendron, \"Bundle-based relaxation methods for multicommodity capacitated fixed charge network design\", Discrete Applied Mathematics 112, 2001."

function __init__()
    register(
        DataDep(
            datadep_name(CanadC()),
            CANADC_MESSAGE,
            "https://commalab.di.unipi.it/files/Data/MMCF/C.tgz",
            "71c4bc1a27aa2b66680e0891503610ceb52a0e95e3ca40235f94e1d384bb15fe";
            post_fetch_method=unpack,
        ),
    )
    return nothing
end
