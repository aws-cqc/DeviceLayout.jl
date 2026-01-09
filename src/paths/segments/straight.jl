"""
    mutable struct Straight{T} <: ContinuousSegment{T}

A straight line segment is parameterized by its length.
It begins at a point `p0` with initial angle `α0`.
"""
mutable struct Straight{T} <: ContinuousSegment{T}
    l::T
    p0::Point{T}
    α0::typeof(1.0°)
end
(s::Straight)(t) = s.p0 + Point(t * cos(s.α0), t * sin(s.α0))

"""
    Straight(l::T; p0::Point=Point(zero(T),zero(T)), α0=0.0°) where {T<:Coordinate}

Outer constructor for `Straight` segments.
"""
Straight(l::T; p0::Point=Point(zero(T), zero(T)), α0=0.0°) where {T <: Coordinate} =
    Straight{T}(l, p0, α0)
Straight(l::T, p0::Point{T}, α0::Real) where {T} = Straight{T}(l, p0, α0)
convert(::Type{Straight{T}}, x::Straight) where {T} =
    Straight{T}(convert(T, x.l), convert(Point{T}, x.p0), x.α0)
convert(::Type{Segment{T}}, x::Straight) where {T} = convert(Straight{T}, x)

copy(s::Straight{T}) where {T} = Straight{T}(s.l, s.p0, s.α0)
pathlength(s::Straight) = s.l
p0(s::Straight) = s.p0
α0(s::Straight) = s.α0
# positive curvature radius is a left handed turn, negative right handed.
curvatureradius(s::Straight{T}, length) where {T} = Inf * oneunit(T)
summary(s::Straight) = "Straight by $(s.l)"

function pathlength_nearest(seg::Paths.Straight, pt::Point)
    pt_rel = pt - p0(seg)
    s = pt_rel.x * cos(α0(seg)) + pt_rel.y * sin(α0(seg)) # pt_rel ⋅ seg direction
    return max(min(pathlength(seg), s), zero(s))
end

"""
    line_segments(seg::Straight)

Return a vector with a [`Polygons.LineSegment`](@ref) object corresponding to `seg`.
"""
function line_segments(seg::Straight)
    return [Polygons.LineSegment(p0(seg), p1(seg))]
end

"""
    setp0!(s::Straight, p::Point)

Set the p0 of a straight segment.
"""
setp0!(s::Straight, p::Point) = s.p0 = p

"""
    setα0!(s::Straight, α0′)

Set the angle of a straight segment.
"""
setα0!(s::Straight, α0′) = s.α0 = α0′

α1(s::Straight) = s.α0

"""
    straight!(p::Path, l::Coordinate, sty::Style=nextstyle(p))

Extend a path `p` straight by length `l` in the current direction. By default,
we take the last continuous style in the path.
"""
function straight!(p::Path, l::Coordinate, sty::Style=nextstyle(p))
    T = coordinatetype(p)
    dimension(T) != dimension(typeof(l)) && throw(DimensionError(T(1), l))
    l < zero(l) && throw(ArgumentError("Tried to go straight by a negative amount."))
    seg = Straight{T}(l, p1(p), α1(p))

    if !isempty(p) && (segment(last(p)) isa Paths.Corner)
        cseg = segment(last(p))
        minlen = cseg.extent * tan(abs(0.5 * cseg.α))
        if l <= minlen
            throw(ArgumentError("Straight following corner needs minimum length $l."))
        end

        # convert takes NoRender() → NoRenderContinuous()
        push!(p, Node(seg, convert(ContinuousStyle, sty)))

        pa = split(p[end], minlen)
        setstyle!(pa[1], SimpleNoRender(2 * cseg.extent))
        splice!(p, length(p), pa)
    else
        # convert takes NoRender() → NoRenderContinuous()
        push!(p, Node(seg, convert(ContinuousStyle, sty)))
    end
    return nothing
end

function _split(seg::Straight{T}, x) where {T}
    s1 = Straight{T}(x, seg.p0, seg.α0)
    s2 = Straight{T}(seg.l - x, seg(x), seg.α0)
    return s1, s2
end

direction(s::Straight, t) = s.α0
