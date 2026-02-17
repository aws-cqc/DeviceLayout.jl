"""
    mutable struct Turn{T} <: ContinuousSegment{T}

A circular turn is parameterized by the turn angle `α` and turning radius `r`.
It begins at a point `p0` with initial angle `α0`.
"""
mutable struct Turn{T} <: ContinuousSegment{T}
    α::typeof(1.0°)
    r::T
    p0::Point{T}
    α0::typeof(1.0°)
end
function (s::Turn)(t)
    # assuming s.α not zero
    x = ifelse(s.r == zero(s.r), typeof(s.r)(one(s.r)), s.r) # guard against div by zero
    cen = s.p0 + Point(-s.r * sign(s.α)sin(s.α0), s.r * sign(s.α)cos(s.α0))
    return cen + Point(
        s.r * (cos(s.α0) * sin(t / x) + sign(s.α) * sin(s.α0) * cos(t / x)),
        s.r * (sin(s.α0) * sin(t / x) - sign(s.α) * cos(s.α0) * cos(t / x))
    )
end

"""
    Turn(α, r::T, p0::Point{T}=Point(0.0,0.0), α0=0.0°) where {T<:Coordinate}

Outer constructor for `Turn` segments.
"""
Turn(α, r::T; p0::Point=Point(zero(T), zero(T)), α0=0.0°) where {T <: Coordinate} =
    Turn{T}(α, r, p0, α0)
convert(::Type{Turn{T}}, x::Turn) where {T} =
    Turn{T}(x.α, T(x.r), convert(Point{T}, x.p0), x.α0)
convert(::Type{Segment{T}}, x::Turn) where {T} = convert(Turn{T}, x)
copy(s::Turn{T}) where {T} = Turn{T}(s.α, s.r, s.p0, s.α0)

pathlength(s::Turn{T}) where {T} = convert(T, abs(s.r * s.α))
p0(s::Turn) = s.p0
α0(s::Turn) = s.α0
# positive curvature radius is a left handed turn, negative right handed.
curvatureradius(s::Turn, length) = s.α > zero(s.α) ? s.r : -s.r
summary(s::Turn) = "Turn by $(s.α) with radius $(s.r)"
function curvaturecenter(s::Turn{T}) where {T}
    return p0(s) + curvatureradius(s, zero(T)) * Point(-sin(α0(s)), cos(α0(s)))
end

function pathlength_nearest(seg::Paths.Turn, pt::Point)
    dir = sign(seg.α)
    # get pt relative to center of turn circle
    pt_rel = pt - curvaturecenter(seg)

    # find out whether point is in the sector of the turn
    # value in [0, 2π] if CCW, [-2π, 0] if CW
    rnd = (dir < 0 ? RoundUp : RoundDown)
    α_s = rem2pi(atan(pt_rel.y, pt_rel.x), rnd)

    dα = rem2pi(α_s - (α0(seg) - dir * 90°), rnd)
    dα_1 = rem2pi(seg.α - dα, rnd)

    in_sector = (abs(dα) < abs(seg.α)) || abs(seg.α) > 2π
    in_sector && return seg.r * abs(dα)

    p0_nearest = abs(rem2pi(dα, RoundNearest)) < abs(rem2pi(dα_1, RoundNearest))
    return seg.r * (p0_nearest ? 0 : uconvert(NoUnits, abs(seg.α)))
end

"""
    setp0!(s::Turn, p::Point)

Set the p0 of a turn.
"""
setp0!(s::Turn, p::Point) = s.p0 = p

"""
    setα0!(s::Turn, α0′)

Set the starting angle of a turn.
"""
setα0!(s::Turn, α0′) = s.α0 = α0′

α1(s::Turn) = s.α0 + s.α

"""
    turn!(p::Path, α, r::Coordinate, sty::Style=nextstyle(p))

Turn a path `p` by angle `α` with a turning radius `r` in the current direction.
Positive angle turns left. By default, we take the last continuous style in the path.
"""
function turn!(p::Path, α, r::Coordinate, sty::Style=nextstyle(p))
    T = coordinatetype(p)
    dimension(T) != dimension(typeof(r)) && throw(DimensionError(T(1), r))
    !isempty(p) &&
        (segment(last(p)) isa Paths.Corner) &&
        error("`Paths.Straight` segments must follow `Paths.Corner`s.")
    seg = Turn{T}(α, r, p1(p), α1(p))
    push!(p, Node(seg, convert(ContinuousStyle, sty)))
    return nothing
end

"""
    turn!(p::Path, str::String, r::Coordinate, sty::Style=nextstyle(p))

Turn a path `p` with direction coded by string `str`:

  - "l": turn by 90° (left)
  - "r": turn by -90° (right)
  - "lrlrllrrll": do those turns in that order

By default, we take the last continuous style in the path.
"""
function turn!(p::Path, str::String, r::Coordinate, sty::Style=nextstyle(p))
    T = coordinatetype(p)
    dimension(T) != dimension(typeof(r)) && throw(DimensionError(T(1), r))
    !isempty(p) &&
        (segment(last(p)) isa Paths.Corner) &&
        error("`Paths.Straight` segments must follow `Paths.Corner`s.")
    for ch in str
        if ch == 'l'
            α = 90°
        elseif ch == 'r'
            α = -90°
        else
            error("Unrecognizable turn command.")
        end
        seg = Turn{T}(α, r, p1(p), α1(p))
        # convert takes NoRender() → NoRenderContinuous()
        push!(p, Node(seg, convert(ContinuousStyle, sty)))
    end
    return nothing
end

function _split(seg::Turn{T}, x) where {T}
    r, α = seg.r, seg.α
    α1 = sign(α) * x / r
    α2 = α - α1
    s1 = Turn{T}(α1, seg.r, seg.p0, seg.α0)
    s2 = Turn{T}(α2, seg.r, seg(x), seg.α0 + α1)
    return s1, s2
end

direction(s::Turn, t) = s.α0 + s.α * (t / pathlength(s))
