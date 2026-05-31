"""
    period_steps(p::Period, step::Period; roundup=floor)::Int

Compute how many complete `step` units fit into period `p`.

# Arguments
- `p::Period`: the period to measure
- `step::Period`: the step size
- `roundup::Function`: `floor` (default) or `ceil`

# Returns
An integer representing the number of steps.

# Examples
```julia
period_steps(Day(10), Week(1))                   # => 1 (default floor)
period_steps(Day(10), Week(1); roundup=ceil)     # => 2
period_steps(Hour(25), Week(1))                  # => 2
period_steps(Day(1), Hour(12); roundup=ceil)     # => 1
```
"""
function period_steps(p::Dates.Period, step::Dates.Period; roundup=floor)
    floored_or_ceiled = roundup(p, step)
    return div(Dates.value(floored_or_ceiled), Dates.value(step))
end
