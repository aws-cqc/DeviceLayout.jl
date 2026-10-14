abstract type Strands{T} <: ContinuousStyle{T} end

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
extent(s::SimpleStrands, t...) = s.offset + (s.num) * (s.width) + (s.num - 1) * (s.spacing)
offset(s::SimpleStrands, t...) = s.offset
width(s::SimpleStrands, t...) = s.width
spacing(s::SimpleStrands, t...) = s.spacing
num(s::SimpleStrands, t...) = s.num
translate(s::SimpleStrands, t) = copy(s)
reverse(s::SimpleStrands, l) = s

"""
    Strands(offset::Coordinate, width::Coordinate, spacing::Coordinate, num::Int)

                  example for num = 2
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    |||     |||                         |||     |||
    <-><---><-><-----------|-----------><-><---><->
     w   s   w    offset                 w   s   w

Constructor for `SimpleStrands` styles.
"""
function Strands(offset::Coordinate, width::Coordinate, spacing::Coordinate, num::Int)
    dimension(offset) != dimension(width) && throw(DimensionError(offset, width))
    dimension(spacing) != dimension(width) && throw(DimensionError(spacing, width))
    dimension(spacing) != dimension(offset) && throw(DimensionError(spacing, offset))
    o, w, s = promote(float(offset), float(width), float(spacing))
    return SimpleStrands(o, w, s, num)
end

summary(s::SimpleStrands) = string(
    s.num,
    " strands with center offset ",
    s.offset,
    ", width ",
    s.width,
    ", and spacing ",
    s.spacing
)
