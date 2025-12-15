"""
Tests for network graph data structures: NetworkNode and NetworkArc
"""

@testset "NetworkNode creation" begin
    @test begin
        node = NetworkNode(; id="1", cost=10.0, capacity=100, info=nothing)
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
            id="platform_A", cost=25.0, capacity=500, info=NodeMetadata(:warehouse, "USA")
        )
        node.info.node_type == :warehouse && node.info.country == "USA"
    end
end

@testset "NetworkNode capacity and cost" begin
    # Test various capacity and cost values
    @test begin
        node_small = NetworkNode(; id="1", cost=5.0, capacity=10, info=nothing)
        node_large = NetworkNode(; id="2", cost=100.0, capacity=10000, info=nothing)
        node_small.capacity < node_large.capacity && node_small.cost < node_large.cost
    end

    # Test zero capacity edge case
    @test begin
        node_zero = NetworkNode(; id="0", cost=0.0, capacity=0, info=nothing)
        node_zero.capacity == 0
    end
end

@testset "NetworkArc with LinearArcCost" begin
    @test begin
        arc = NetworkArc(;
            origin_id="1", destination_id="2", cost=LinearArcCost(5.0), info=nothing
        )
        arc.origin_id == "1" &&
            arc.destination_id == "2" &&
            arc.cost.cost_per_unit_size == 5.0
    end
end

@testset "NetworkArc with BinPackingArcCost" begin
    @test begin
        arc = NetworkArc(;
            origin_id="A",
            destination_id="B",
            cost=BinPackingArcCost(100.0, 50.0),
            info=nothing,
        )
        arc.cost.cost_per_bin == 100.0 && arc.cost.bin_capacity == 50.0
    end
end

@testset "NetworkArc with custom info" begin
    @test begin
        struct ArcMetadata
            transport_mode::Symbol
            distance_km::Float64
        end
        arc = NetworkArc(;
            origin_id="warehouse",
            destination_id="distribution_center",
            cost=LinearArcCost(2.5),
            info=ArcMetadata(:truck, 150.5),
        )
        arc.info.transport_mode == :truck && arc.info.distance_km == 150.5
    end
end

@testset "NetworkArc self-loops" begin
    @test begin
        arc = NetworkArc(;
            origin_id="1", destination_id="1", cost=LinearArcCost(1.0), info=nothing
        )
        arc.origin_id == arc.destination_id
    end
end

@testset "NetworkArc cost function types" begin
    # Test that different cost function types can be used
    @test begin
        linear_arc = NetworkArc(;
            origin_id="1", destination_id="2", cost=LinearArcCost(3.0), info=nothing
        )
        bin_arc = NetworkArc(;
            origin_id="1",
            destination_id="2",
            cost=BinPackingArcCost(75.0, 60.0),
            info=nothing,
        )
        typeof(linear_arc.cost) != typeof(bin_arc.cost)
    end
end

@testset "NetworkArc capacity field" begin
    @test begin
        # LinearArcCost doesn't have a capacity field, but arc can still exist
        arc1 = NetworkArc(;
            origin_id="1", destination_id="2", cost=LinearArcCost(1.0), info=nothing
        )
        # BinPackingArcCost has bin_capacity
        arc2 = NetworkArc(;
            origin_id="1",
            destination_id="2",
            cost=BinPackingArcCost(100.0, 75.0),
            info=nothing,
        )
        arc1.cost isa LinearArcCost && arc2.cost.bin_capacity == 75.0
    end
end

@testset "NetworkArc with Inbound metadata" begin
    @test begin
        struct InboundArcInfo
            arc_type::Symbol
        end
        arc = NetworkArc(;
            origin_id="supplier",
            destination_id="plant",
            cost=LinearArcCost(4.5),
            info=InboundArcInfo(:direct),
        )
        arc.info.arc_type == :direct
    end
end

@testset "Multiple arcs between same nodes with different costs" begin
    @test begin
        arc1 = NetworkArc(;
            origin_id="1", destination_id="2", cost=LinearArcCost(2.0), info=nothing
        )
        arc2 = NetworkArc(;
            origin_id="1", destination_id="2", cost=LinearArcCost(3.0), info=nothing
        )
        arc3 = NetworkArc(;
            origin_id="1",
            destination_id="2",
            cost=BinPackingArcCost(50.0, 40.0),
            info=nothing,
        )
        arc1.cost.cost_per_unit_size < arc2.cost.cost_per_unit_size &&
            typeof(arc1.cost) != typeof(arc3.cost)
    end
end

@testset "String IDs for nodes and arcs" begin
    @test begin
        node1 = NetworkNode(; id="node_001", cost=1.0, capacity=100, info=nothing)
        node2 = NetworkNode(; id="node_002", cost=2.0, capacity=200, info=nothing)
        arc = NetworkArc(;
            origin_id="node_001",
            destination_id="node_002",
            cost=LinearArcCost(0.5),
            info=nothing,
        )
        arc.origin_id == node1.id && arc.destination_id == node2.id
    end
end
