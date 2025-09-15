abstract type Strands{T} <: ContinuousStyle{T} end

"""
    struct GeneralStrands{S,T,U} <: Strands{false}
        offset::S
        width::T
        spacing::U
        num::Int
    end

                  example for num = 2
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    <-><---><-><-----------|-----------><-><---><->
     w   s   w    offset                 w   s   w

Strands with variable center offset, width, and spacing as a function of path length.
`offset`, `width`, and `spacing` are callable.
"""
struct GeneralStrands{S, T, U} <: Strands{false}
    offset::S
    width::T
    spacing::U
    num::Int
end
copy(x::GeneralStrands) = GeneralStrands(x.offset, x.width, x.spacing, x.num)
GeneralStrands(o, w, s, n) = GeneralStrands{typeof(o), typeof(w), typeof(s)}(o, w, s, n)
extent(s::GeneralStrands, t) =
    s.offset(t) + (s.num) * (s.width(t)) + (s.num - 1) * (s.spacing(t))
offset(s::GeneralStrands, t) = s.offset(t)
width(s::GeneralStrands, t) = s.width(t)
spacing(s::GeneralStrands, t) = s.spacing(t)
num(s::GeneralStrands, t...) = s.num
translate(s::GeneralStrands, t) =
    GeneralStrands(x -> s.offset(x + t), x -> s.width(x + t), x -> s.spacing(x + t), s.num)

"""
    struct SimpleStrands{T<:Coordinate} <: Strands{false}
        offset::T
        width::T
        spacing::T
        num::Int
    end

                  example for num = 2
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    <-><---><-><-----------|-----------><-><---><->
     w   s   w    offset                 w   s   w

Strands with fixed center offset, width, and spacing as a function of path length.
"""
struct SimpleStrands{T <: Coordinate} <: Strands{false}
    offset::T
    width::T
    spacing::T
    num::Int
end
copy(x::SimpleStrands) = SimpleStrands(x.offset, x.width, x.spacing, x.num)
extent(s::SimpleStrands, t...) = s.offset + (s.num) * (s.width + (s.num - 1) * (s.spacing))
offset(s::SimpleStrands, t...) = s.offset
width(s::SimpleStrands, t...) = s.width
spacing(s::SimpleStrands, t...) = s.spacing
num(s::SimpleStrands, t...) = s.num
translate(s::SimpleStrands, t) = copy(s)

"""
    Strands(offset::Coordinate, width::Coordinate, spacing::Coordinate, num::Int)
    Strands(offset, width::Coordinate, spacing::Coordinate, num::Int)
    Strands(offset::Coordinate, width, spacing::Coordinate, num::Int)
    Strands(offset::Coordinate, width::Coordinate, spacing, num::Int)
    Strands(offset::Coordinate, width, spacing, num::Int)
    Strands(offset, width::Coordinate, spacing, num::Int)
    Strands(offset, width, spacing::Coordinate, num::Int)
    Strands(offset, width, spacing, num::Int)

                  example for num = 2
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    <-><---><-><-----------|-----------><-><---><->
     w   s   w    offset                 w   s   w

Constructors for Strands styles. Automatically chooses between `SimpleStrands`or
`GeneralStrands` styles as appropriate.
"""
function Strands(offset::Coordinate, width::Coordinate, spacing::Coordinate, num::Int)
    dimension(offset) != dimension(width) && throw(DimensionError(offset, width))
    dimension(spacing) != dimension(width) && throw(DimensionError(spacing, width))
    dimension(spacing) != dimension(offset) && throw(DimensionError(spacing, offset))
    o, w, s = promote(float(offset), float(width), float(spacing))
    return SimpleStrands(o, w, s, num)
end
Strands(offset, width::Coordinate, spacing::Coordinate, num::Int) =
    GeneralStrands(offset, x -> float(width), x -> float(spacing), num)
Strands(offset::Coordinate, width, spacing::Coordinate, num::Int) =
    GeneralStrands(x -> float(offset), width, x -> float(spacing), num)
Strands(offset::Coordinate, width::Coordinate, spacing, num::Int) =
    GeneralStrands(x -> float(offset), x -> float(width), spacing, num)
Strands(offset::Coordinate, width, spacing, num::Int) =
    GeneralStrands(x -> float(offset), width, spacing, num)
Strands(offset, width::Coordinate, spacing, num::Int) =
    GeneralStrands(offset, x -> float(width), spacing, num)
Strands(offset, width, spacing::Coordinate, num::Int) =
    GeneralStrands(offset, width, x -> float(spacing), num)
Strands(offset, width, spacing, num::Int) = GeneralStrands(offset, width, spacing, num)

summary(::GeneralStrands) = "Strands with variable center offset, width, and spacing"
summary(s::SimpleStrands) = string(
    num,
    " strands with center offset ",
    s.offset,
    ", width ",
    s.width,
    ", and spacing ",
    s.spacing
)
