"""
Tests for network graph data structures: NetworkNode and NetworkArc
"""

using Graphs
using NetworkDesignOptimization
using Test

@testset "NetworkNode creation" begin
    @test begin
        node = NetworkNode(;
            id="1", node_type=:origin, cost=10.0, capacity=100, info=nothing
        )
        node.id == "1" && node.cost == 10.0 && node.capacity == 100
    end
end

@testset "NetworkNode with custom info" begin
    @test begin
        struct NodeMetadata
            node_type::Symbol
            country::String
        end
        node = NetworkNode(;
            id="platform_A",
            node_type=:other,
            cost=25.0,
            capacity=500,
            info=NodeMetadata(:warehouse, "USA"),
        )
        node.info.node_type == :warehouse && node.info.country == "USA"
    end
end

@testset "NetworkNode capacity and cost" begin
    # Test various capacity and cost values
    @test begin
        node_small = NetworkNode(;
            id="1", node_type=:origin, cost=5.0, capacity=10, info=nothing
        )
        node_large = NetworkNode(;
            id="2", node_type=:destination, cost=100.0, capacity=10000, info=nothing
        )
        node_small.capacity < node_large.capacity && node_small.cost < node_large.cost
    end

    # Test zero capacity edge case
    @test begin
        node_zero = NetworkNode(;
            id="0", node_type=:destination, cost=0.0, capacity=0, info=nothing
        )
        node_zero.capacity == 0
    end
end

@testset "NetworkArc with LinearArcCost" begin
    @test begin
        arc = NetworkArc(; travel_time_steps=0, cost=LinearArcCost(5.0), info=nothing)
        arc.travel_time_steps == 0 && arc.cost.cost_per_unit_size == 5.0
    end
end

@testset "NetworkArc with BinPackingArcCost" begin
    @test begin
        arc = NetworkArc(;
            travel_time_steps=0, cost=BinPackingArcCost(100.0, 50.0), info=nothing
        )
        arc.travel_time_steps == 0 &&
            arc.cost.cost_per_bin == 100.0 &&
            arc.cost.bin_capacity == 50.0
    end
end

@testset "NetworkArc with custom info" begin
    @test begin
        struct ArcMetadata
            transport_mode::Symbol
            distance_km::Float64
        end
        arc = NetworkArc(;
            travel_time_steps=0, cost=LinearArcCost(2.5), info=ArcMetadata(:truck, 150.5)
        )
        arc.travel_time_steps == 0 &&
            arc.info.transport_mode == :truck &&
            arc.info.distance_km == 150.5
    end
end

@testset "NetworkArc cost function types" begin
    # Test that different cost function types can be used
    @test begin
        linear_arc = NetworkArc(;
            travel_time_steps=0, cost=LinearArcCost(3.0), info=nothing
        )
        bin_arc = NetworkArc(;
            travel_time_steps=0, cost=BinPackingArcCost(75.0, 60.0), info=nothing
        )
        linear_arc.travel_time_steps == 0 &&
            bin_arc.travel_time_steps == 0 &&
            typeof(linear_arc.cost) != typeof(bin_arc.cost)
    end
end

@testset "NetworkArc capacity field" begin
    @test begin
        # LinearArcCost doesn't have a capacity field, but arc can still exist
        arc1 = NetworkArc(; travel_time_steps=0, cost=LinearArcCost(1.0), info=nothing)
        # BinPackingArcCost has bin_capacity
        arc2 = NetworkArc(;
            travel_time_steps=0, cost=BinPackingArcCost(100.0, 75.0), info=nothing
        )
        arc1.travel_time_steps == 0 &&
            arc2.travel_time_steps == 0 &&
            arc1.cost isa LinearArcCost &&
            arc2.cost.bin_capacity == 75.0
    end
end

@testset "NetworkArc with Inbound metadata" begin
    @test begin
        struct InboundArcInfo
            arc_type::Symbol
        end
        arc = NetworkArc(;
            travel_time_steps=0, cost=LinearArcCost(4.5), info=InboundArcInfo(:direct)
        )
        arc.travel_time_steps == 0 && arc.info.arc_type == :direct
    end
end

@testset "Multiple arcs between same nodes with different costs" begin
    @test begin
        arc1 = NetworkArc(; travel_time_steps=0, cost=LinearArcCost(2.0), info=nothing)
        arc2 = NetworkArc(; travel_time_steps=0, cost=LinearArcCost(3.0), info=nothing)
        arc3 = NetworkArc(;
            travel_time_steps=0, cost=BinPackingArcCost(50.0, 40.0), info=nothing
        )
        arc1.travel_time_steps == 0 &&
            arc2.travel_time_steps == 0 &&
            arc3.travel_time_steps == 0 &&
            arc1.cost.cost_per_unit_size < arc2.cost.cost_per_unit_size &&
            typeof(arc1.cost) != typeof(arc3.cost)
    end
end

@testset "String IDs for nodes and arcs" begin
    @test begin
        node1 = NetworkNode(;
            id="node_001", node_type=:origin, cost=1.0, capacity=100, info=nothing
        )
        node2 = NetworkNode(;
            id="node_002", node_type=:destination, cost=2.0, capacity=200, info=nothing
        )
        arc = NetworkArc(; travel_time_steps=0, cost=LinearArcCost(0.5), info=nothing)
        arc.travel_time_steps == 0
    end
end

@testset "TimeSpaceGraph creation" begin
    @test begin
        nodes = [
            NetworkNode(; id="A", node_type=:origin, cost=0.0, capacity=10, info=nothing),
            NetworkNode(;
                id="B", node_type=:destination, cost=0.0, capacity=10, info=nothing
            ),
        ]
        arcs = [
            (
                "A",
                "B",
                NetworkArc(; travel_time_steps=1, cost=LinearArcCost(1.0), info=nothing),
            ),
        ]
        network_graph = NetworkGraph(nodes, arcs)
        time_horizon_length = 3
        tsg = TimeSpaceGraph(network_graph, time_horizon_length)

        # Basic creation checks
        tsg isa TimeSpaceGraph &&
            time_horizon(tsg) == 1:3 &&
            Graphs.nv(tsg.graph) == 6 &&  # 2 nodes * 3 time steps
            Graphs.ne(tsg.graph) == 3 &&   # 1 arc * 3 time steps

            # Vertex labels and data
            haskey(tsg.graph, ("A", 1)) &&
            haskey(tsg.graph, ("A", 2)) &&
            haskey(tsg.graph, ("A", 3)) &&
            haskey(tsg.graph, ("B", 1)) &&
            haskey(tsg.graph, ("B", 2)) &&
            haskey(tsg.graph, ("B", 3)) &&
            tsg.graph[("A", 1)].id == "A" &&
            tsg.graph[("B", 1)].id == "B" &&

            # Edge labels and data (including wrapping)
            haskey(tsg.graph, ("A", 1), ("B", 2)) &&
            haskey(tsg.graph, ("A", 2), ("B", 3)) &&
            haskey(tsg.graph, ("A", 3), ("B", 1)) &&  # wrapping: 3+1=4 >3, 4-3=1
            tsg.graph[("A", 1), ("B", 2)].travel_time_steps == 1
    end
end

@testset "TravelTimeGraph creation and data" begin
    @test begin
        nodes = [
            NetworkNode(; id="O", node_type=:origin, cost=0.0, capacity=10, info=nothing),
            NetworkNode(;
                id="D", node_type=:destination, cost=0.0, capacity=10, info=nothing
            ),
        ]
        arcs = [
            (
                "O",
                "D",
                NetworkArc(; travel_time_steps=1, cost=LinearArcCost(1.0), info=nothing),
            ),
        ]
        network_graph = NetworkGraph(nodes, arcs)
        # Create a bundle with one order
        order = Order(;
            commodities=[
                LightCommodity(;
                    origin_id="O",
                    destination_id="D",
                    size=1.0,
                    info=nothing,
                    is_date_arrival=true,
                ),
            ],
            time_step=1,
            max_transit_steps=2,
        )
        bundle = Bundle(; orders=[order], origin_id="O", destination_id="D")
        bundles = [bundle]
        ttg = TravelTimeGraph(network_graph, bundles)

        # Basic creation checks
        ttg isa TravelTimeGraph &&
            time_horizon(ttg) == 0:2 &&
            Graphs.nv(ttg.graph) == 4 &&  # O0,O1,O2, D0
            Graphs.ne(ttg.graph) == 3 &&   # 2 shortcuts O, 1 transport arc (O1->D0)

            # Vertex labels and data
            haskey(ttg.graph, ("O", 0)) &&
            haskey(ttg.graph, ("O", 1)) &&
            haskey(ttg.graph, ("O", 2)) &&
            haskey(ttg.graph, ("D", 0)) &&
            !haskey(ttg.graph, ("D", 1)) &&
            ttg.graph[("O", 0)].id == "O" &&
            ttg.graph[("D", 0)].id == "D" &&

            # Edge labels and data (Count Down)
            haskey(ttg.graph, ("O", 2), ("O", 1)) &&  # wait origin
            haskey(ttg.graph, ("O", 1), ("O", 0)) &&  # wait origin
            haskey(ttg.graph, ("O", 1), ("D", 0)) &&  # transport arc
            !haskey(ttg.graph, ("O", 2), ("D", 1)) &&  # D1 doesn't exist
            !haskey(ttg.graph, ("O", 0), ("D", 0)) &&  # no edge from O0 to D0
            ttg.graph[("O", 1), ("D", 0)].travel_time_steps == 1
    end
end
