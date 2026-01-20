using Test
using TransportationPlanningOptimization
using Graphs
using MetaGraphsNext
using SparseArrays

@testset "TravelTimeGraph cost matrix" begin
    origin = NetworkNode(; id="O", node_type=:origin)
    destination = NetworkNode(; id="D", node_type=:destination)
    nodes = [origin, destination]
    arc = NetworkArc(; travel_time_steps=0, cost=LinearArcCost(1.0))
    arcs = [(origin.id, destination.id, arc)]
    net = NetworkGraph(nodes, arcs)

    c = LightCommodity(; origin_id=origin.id, destination_id=destination.id, size=1.0)
    order = Order(; commodities=[c], time_step=1, max_transit_steps=1)
    bundle = Bundle(; orders=[order], origin_id=origin.id, destination_id=destination.id)

    ttg = TravelTimeGraph(net, [bundle])

    @test typeof(ttg.cost_matrix) == SparseMatrixCSC{Float64,Int}
    @test size(ttg.cost_matrix) == (nv(ttg.graph), nv(ttg.graph))
    @test nnz(ttg.cost_matrix) == ne(ttg.graph)

    for (u_id, v_id) in edge_labels(ttg.graph)
        i = code_for(ttg.graph, u_id)
        j = code_for(ttg.graph, v_id)
        @test ttg.cost_matrix[i, j] == 0.0
    end
end
