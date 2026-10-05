const _SOLUTION_CSV_COLUMNS = [:commodity, :leg, :arc, :departure, :arrival, :quantity]

"""
$TYPEDSIGNATURES

Write the routes of `solution` to the CSV file `path` and return `path`.
There is one row per leg with columns `commodity` (index of the input commodity), `leg` (1-based position in its route), `arc` (index of the input arc), `departure`, `arrival` and `quantity`.
Commodities with an empty route have no rows, and `arc_flows` are not written (see [`read_solution_csv`](@ref)).
"""
function write_solution_csv(path::AbstractString, solution::Solution)
    rows = [
        (; commodity=k, leg=i, leg_k.arc, leg_k.departure, leg_k.arrival, leg_k.quantity)
        for (k, route) in enumerate(solution.routes) for (i, leg_k) in enumerate(route)
    ]
    CSV.write(path, rows)
    return path
end

"""
$TYPEDSIGNATURES

Read the routes written by [`write_solution_csv`](@ref) from the CSV file `path` and return the [`Solution`](@ref) of `instance`, built with `Solution(routes, instance)`.
The flows and the cost are rebuilt from the routes, so bins are repacked and the cost equals that of the written solution only for linear costs.
Rows can come in any order, since legs are placed by their `leg` number, and commodities without rows get an empty route.

A missing column throws an `ArgumentError` naming it.
An `ArgumentError` with the row number (counting the non-empty rows after the header, the first being row 1) is thrown for a missing or unparsable value, a `commodity` outside the input commodities of `instance`, or leg numbers of a commodity that are not exactly `1:n`.
Extra fields in a row are ignored with a CSV warning.
Routes that are not a valid plan on `instance` are rejected by `Solution(routes, instance)`, but capacity is not checked, run [`is_feasible`](@ref) on the result.
"""
function read_solution_csv(path::AbstractString, instance::Instance)
    types = Dict(
        :commodity => Int,
        :leg => Int,
        :arc => Int,
        :departure => DateTime,
        :arrival => DateTime,
        :quantity => Int,
    )
    file = CSV.File(path; types, validate=false)
    missing_columns = setdiff(_SOLUTION_CSV_COLUMNS, propertynames(file))
    isempty(missing_columns) ||
        throw(ArgumentError("$path: missing columns $(join(missing_columns, ", "))"))
    n = length(instance.input.commodities)
    # Per commodity, `leg number => (leg, row number)`.
    legs = [Dict{Int,Tuple{Leg,Int}}() for _ in 1:n]
    for (r, row) in enumerate(file)
        fail(message) = throw(ArgumentError("$path, row $r: $message"))
        for column in _SOLUTION_CSV_COLUMNS
            ismissing(row[column]) && fail("missing or unparsable value in column $column")
        end
        1 <= row.commodity <= n || fail("commodity $(row.commodity) is outside 1:$n")
        row.leg >= 1 ||
            fail("leg number $(row.leg) of commodity $(row.commodity) is not positive")
        haskey(legs[row.commodity], row.leg) &&
            fail("duplicate leg $(row.leg) of commodity $(row.commodity)")
        leg = Leg(;
            arc=row.arc, departure=row.departure, arrival=row.arrival, quantity=row.quantity
        )
        legs[row.commodity][row.leg] = (leg, r)
    end
    routes = map(1:n) do k
        numbers = sort!(collect(keys(legs[k])))
        gap = findfirst(i -> numbers[i] != i, eachindex(numbers))
        isnothing(gap) || throw(
            ArgumentError(
                "$path, row $(legs[k][numbers[gap]][2]): commodity $k has no leg $gap, " *
                "leg numbers must be exactly 1:$(length(numbers))",
            ),
        )
        return [legs[k][i][1] for i in numbers]
    end
    return Solution(routes, instance)
end
