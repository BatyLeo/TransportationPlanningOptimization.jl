using Test
using TransportationPlanningOptimization
const TPO = TransportationPlanningOptimization

include(joinpath(@__DIR__, "..", "scripts", "outbound", "Outbound.jl"))

const DATAMVP_DIR = joinpath(@__DIR__, "..", "data", "outbound", "dataMVP")

@testset "Outbound dataMVP parser" begin
    parsed = Outbound.parse_dataMVP_instance(DATAMVP_DIR)

    # --- Shape checks
    @test !isempty(parsed.nodes)
    @test !isempty(parsed.arcs)
    @test !isempty(parsed.commodities)

    # --- Node taxonomy
    @test any(n -> n.node_type === :origin, parsed.nodes)
    @test any(n -> n.node_type === :destination, parsed.nodes)

    # --- Multi-modal candidates exist
    # After Task 3 + dedup, parsed.arcs is one Arc per unique (origin,
    # destination, mode) triple. Multi-modal legs surface as duplicate
    # (origin, destination) pairs with different `info.arc_type`.
    counts = Dict{Tuple{String,String},Int}()
    for a in parsed.arcs
        counts[(a.origin_id, a.destination_id)] =
            get(counts, (a.origin_id, a.destination_id), 0) + 1
    end
    n_multi_modal_pairs = count(>(1), values(counts))
    @test n_multi_modal_pairs > 0

    # --- Modes observed match the dataMVP CSV: at least :F and :R must appear.
    modes = Set(a.info.arc_type for a in parsed.arcs)
    @test :F in modes
    @test :R in modes
end
