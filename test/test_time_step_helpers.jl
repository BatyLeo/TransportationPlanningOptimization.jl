using Test
using Dates
using NetworkDesignOptimization: period_steps

@testset "period_steps with TIME_STEP=Week(1)" begin
    # Day to Week conversion
    @test period_steps(Day(10), Week(1); roundup=ceil) == 2
    @test period_steps(Day(10), Week(1); roundup=floor) == 1
    @test period_steps(Day(7), Week(1); roundup=floor) == 1
    @test period_steps(Day(14), Week(1); roundup=floor) == 2

    # Hour to Week conversion (sub-day)
    @test period_steps(Hour(25), Week(1); roundup=ceil) == 1
    @test period_steps(Hour(25), Week(1); roundup=floor) == 0

    # Week to Week
    @test period_steps(Week(2), Week(1); roundup=floor) == 2
    @test period_steps(Week(2), Week(1); roundup=ceil) == 2
end

@testset "period_steps with TIME_STEP=Day(1)" begin
    # Day to Day
    @test period_steps(Day(5), Day(1); roundup=ceil) == 5
    @test period_steps(Day(5), Day(1); roundup=floor) == 5

    # Hour to Day conversion
    @test period_steps(Hour(25), Day(1); roundup=ceil) == 2
    @test period_steps(Hour(23), Day(1); roundup=floor) == 0
    @test period_steps(Hour(24), Day(1); roundup=ceil) == 1

    # Week to Day
    @test period_steps(Week(2), Day(1); roundup=floor) == 14
end

@testset "period_steps with TIME_STEP=Hour(12)" begin
    # Day to Hour conversion
    @test period_steps(Day(1), Hour(12); roundup=floor) == 2
    @test period_steps(Day(1), Hour(12); roundup=ceil) == 2

    # Hour to Hour
    @test period_steps(Hour(12), Hour(12); roundup=floor) == 1
    @test period_steps(Hour(25), Hour(12); roundup=ceil) == 3
    @test period_steps(Hour(25), Hour(12); roundup=floor) == 2
end

@testset "period_steps with zero and negative edge cases" begin
    # Zero periods
    @test period_steps(Day(0), Week(1); roundup=floor) == 0
    @test period_steps(Day(0), Week(1); roundup=ceil) == 0
end

@testset "period_steps with fractional rounding" begin
    @test period_steps(Day(15), Week(1); roundup=ceil) == 3
    @test period_steps(Day(15), Week(1); roundup=floor) == 2

    @test period_steps(Hour(25), Day(1); roundup=ceil) == 2
    @test period_steps(Hour(25), Day(1); roundup=floor) == 1
end

@testset "period_steps integration with time difference" begin
    # Simulate date difference in build_instance
    start_date = Date(2025, 1, 1)

    # Test date 1 week later
    date_7d = Date(2025, 1, 8)
    date_diff_7d = date_7d - start_date
    @test period_steps(date_diff_7d, Week(1); roundup=floor) + 1 == 2

    # Test date 14 days later
    date_14d = Date(2025, 1, 15)
    date_diff_14d = date_14d - start_date
    @test period_steps(date_diff_14d, Week(1); roundup=floor) + 1 == 3

    # Same but with Day(1) TIME_STEP
    @test period_steps(date_diff_7d, Day(1); roundup=floor) + 1 == 8
    @test period_steps(date_diff_14d, Day(1); roundup=floor) + 1 == 15
end
