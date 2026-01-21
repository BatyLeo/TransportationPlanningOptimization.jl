using TransportationPlanningOptimization
using Test
using Dates
using CSV
using DataFrames

@testset "Solution Parsing" begin
    # Setup simple network
    nodes = [
        NetworkNode(; id="A", node_type=:origin),
        NetworkNode(; id="B", node_type=:other),
        NetworkNode(; id="C", node_type=:destination),
    ]
    arc_ab = Arc(;
        origin_id="A", destination_id="B", cost=LinearArcCost(10.0), travel_time=Day(1)
    )
    arc_bc = Arc(;
        origin_id="B", destination_id="C", cost=LinearArcCost(10.0), travel_time=Day(1)
    )

    time_step = Day(1)
    commodities = [
        Commodity(;
            origin_id="A",
            destination_id="C",
            quantity=1,
            departure_date=DateTime(2021, 1, 1),
            max_delivery_time=Day(2),
            size=1.0,
        ),
    ]
    instance = Instance(nodes, [arc_ab, arc_bc], commodities, time_step)

    # Generate a solution
    sol = greedy_construction(instance)
    original_cost = cost(sol)
    @test is_feasible(sol, instance)

    # Temp file for testing using Julia's native mktemp
    mktemp() do tmp_file, tmp_io
        close(tmp_io) # Close the handle as our functions opening the file by path
        # Write to CSV
        write_solution_csv(tmp_file, sol, instance)
        @test isfile(tmp_file)

        # Check CSV content (manually verify structure)
        df = CSV.read(tmp_file, DataFrame)
        @test "bundle_idx" in names(df)
        @test "point_type" in names(df)
        # For A->B->C, we expect 3 points: C (:destination), B (:other), A (:origin)
        @test nrow(df) == 3
        @test df.point_type == ["destination", "other", "origin"]
        @test df.node_id == ["C", "B", "A"]

        # Read from CSV
        sol_read = read_solution_csv(tmp_file, instance)

        # Verify round-trip
        @test is_feasible(sol_read, instance)
        @test cost(sol_read) == original_cost
        @test sol_read.bundle_paths == sol.bundle_paths
    end

    # Additional tests for strict `bundle_idx` enforcement
    mktemp() do tmp_file, tmp_io
        close(tmp_io)
        # Write a canonical CSV using the current writer
        write_solution_csv(tmp_file, sol, instance)
        df = CSV.read(tmp_file, DataFrame)

        # Missing bundle_idx
        df_no_bundle = select(df, Not(:bundle_idx))
        tmp2 = tmp_file * ".nobundle"
        CSV.write(tmp2, df_no_bundle)
        @test_throws ErrorException read_solution_csv(tmp2, instance)

        # Duplicate point_number for same bundle
        df_dup = deepcopy(df)
        df_dup.point_number[1] = df_dup.point_number[2]
        tmp3 = tmp_file * ".dup"
        CSV.write(tmp3, df_dup)
        @test_throws ErrorException read_solution_csv(tmp3, instance)

        # Invalid bundle_idx (out of range)
        df_invalid = deepcopy(df)
        df_invalid.bundle_idx .= 999
        tmp4 = tmp_file * ".invalid"
        CSV.write(tmp4, df_invalid)
        @test_throws ErrorException read_solution_csv(tmp4, instance)
    end
end
