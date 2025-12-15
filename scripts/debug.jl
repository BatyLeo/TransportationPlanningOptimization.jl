struct T1 end
struct T2 end
struct T3 end
struct T4 end
struct T5 end
struct T6 end
struct T7 end
struct T8 end
struct T9 end
struct T10 end
struct T11 end
struct T12 end
struct T13 end
struct T14 end
struct T15 end
struct T16 end
struct T17 end
struct T18 end
struct T19 end
struct T20 end

f(a) = first(a) / 2
value_types = filter(isbitstype, subtypes(Signed))
types = vcat(
    value_types,
    T1,
    T2,
    T3,
    T4,
    T5,
    T6,
    T7,
    T8,
    T9,
    T10,
    T11,
    T12,
    T13,
    T14,
    T15,
    T16,
    T17,
    T18,
    T19,
    T20,
)
using BenchmarkTools
for i in eachindex(types)
    T = Union{types[1:i]...}
    @show T
    @show Base.isbitsunion(T)
    arr = T[one(first(types))]
    println(@btime f($arr))
end
