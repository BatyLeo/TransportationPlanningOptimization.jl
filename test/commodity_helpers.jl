using TransportationPlanningOptimization

# Build a small bag of LightCommodity{Nothing} values for testing.
# Shared by test_merge_sorted_slot.jl and test_drain_first_matches.jl (see the
# guarded include in each file): whichever file loads first defines `_mk` here.
function _mk(size::Float64, sup::String="S", cust::String="C")
    return TransportationPlanningOptimization.LightCommodity(;
        origin_id=sup, destination_id=cust, size=size, info=nothing
    )
end
