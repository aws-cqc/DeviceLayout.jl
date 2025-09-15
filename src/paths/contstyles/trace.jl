abstract type Trace{T} <: ContinuousStyle{T} end

"""
    struct GeneralTrace{T} <: Trace{false}
        width::T
    end

A single trace with variable width as a function of path length. `width` is callable.
"""
struct GeneralTrace{T} <: Trace{false}
    width::T
end
copy(x::GeneralTrace) = GeneralTrace(x.width)
extent(s::GeneralTrace, t) = 0.5 * s.width(t)
extent(s::GeneralTrace) = t -> 0.5 * s.width(t)
width(s::GeneralTrace, t) = s.width(t)
width(s::GeneralTrace) = s.width
trace(s::GeneralTrace, t) = s.width(t)
translate(s::GeneralTrace, t) = GeneralTrace(x -> s.width(x + t))

"""
    struct SimpleTrace{T <: Coordinate} <: Trace{false}
        width::T
    end

A single trace with fixed width as a function of path length.
"""
struct SimpleTrace{T <: Coordinate} <: Trace{false}
    width::T
end
copy(x::SimpleTrace) = Trace(x.width)
extent(s::SimpleTrace, t...) = 0.5 * s.width
width(s::SimpleTrace, t...) = s.width
trace(s::SimpleTrace, t...) = s.width
translate(s::SimpleTrace, t) = copy(s)

"""
    Trace(width)
    Trace(width::Coordinate)
    Trace(width_start::Coordinate, width_end::Coordinate)

Constructor for Trace styles. Automatically chooses `SimpleTrace`, `GeneralTrace`,
and `TaperTrace` as appropriate.
"""
Trace(width) = GeneralTrace(width)
Trace(width::Coordinate) = SimpleTrace(float(width))

summary(::GeneralTrace) = "Trace with variable width"
summary(s::SimpleTrace) = string("Trace with width ", s.width)
