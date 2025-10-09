"""
    abstract type OffsetSegment{T, S <: Segment{T}} <: ContinuousSegment{T}

Supertype for "offset curves", defined by a segment with a signed offset.

An offset curve follows the original curve with some offset in the normal direction,
which may be constant (`ConstantOffset`) or vary with pathlength (`GeneralOffset`).
The curve normal is rotated +90° from the curve tangent, so that a positive offset
corresponds to the "left-hand side" of the curve.

Note that `pathlength(seg::OffsetSegment)` is the length of the original curve, and that
the offset segment is parameterized by the arclength of the original curve.

Used internally during SolidModel rendering. Not fully featured for general use in Paths.
"""
abstract type OffsetSegment{T, S <: Segment{T}} <: ContinuousSegment{T} end

"""
    struct ConstantOffset{T,S} <: OffsetSegment{T,S}
"""
mutable struct ConstantOffset{T, S} <: OffsetSegment{T, S}
    seg::S
    offset::T
end

"""
    struct GeneralOffset{T,S} <: OffsetSegment{T,S}
"""
mutable struct GeneralOffset{T, S} <: OffsetSegment{T, S}
    seg::S
    offset
end

convert(::Type{ConstantOffset{T}}, x::ConstantOffset) where {T} =
    ConstantOffset(convert(Segment{T}, x.seg), convert(T, x.offset))
convert(::Type{ConstantOffset{T}}, x::ConstantOffset{T}) where {T} = x
convert(::Type{Segment{T}}, x::ConstantOffset) where {T} = convert(ConstantOffset{T}, x)

convert(::Type{GeneralOffset{T}}, x::GeneralOffset) where {T} =
    OffsetSegment(convert(Segment{T}, x.seg), x.offset)
convert(::Type{GeneralOffset{T}}, x::GeneralOffset{T}) where {T} = x
convert(::Type{Segment{T}}, x::GeneralOffset) where {T} = convert(GeneralOffset{T}, x)

copy(s::OffsetSegment) = OffsetSegment(copy(s.seg), s.offset)
getoffset(s::ConstantOffset, l...) = s.offset
getoffset(s::GeneralOffset{T}) where {T} = l -> uconvert(unit(T), s.offset(l))
getoffset(s::GeneralOffset, l) = getoffset(s)(l)
offset_derivative(seg::ConstantOffset, s) = 0.0
offset_derivative(seg::GeneralOffset, s) = ForwardDiff.derivative(seg.offset, s)

# "Pathlength" is length of underlying segment!
# That's one reason OffsetSegments are not part of the public API.
pathlength(s::OffsetSegment) = pathlength(s.seg)
# You could get the "true" length using something like this:
# Assuming that s.seg has less than 1 winding!
# pathlength(s.seg) - s.offset * uconvert(NoUnits, α1(s.seg) - α0(s.seg))
# (See _curvelength)
# But this way offset segment is simply parameterized by arclength of the underlying curve
(s::ConstantOffset)(t) =
    s.seg(t) + s.offset * Point(-sin(direction(s.seg, t)), cos(direction(s.seg, t)))
(s::GeneralOffset{T})(t) where {T} =
    s.seg(t) + getoffset(s, t) * Point(-sin(direction(s.seg, t)), cos(direction(s.seg, t)))

p0(s::ConstantOffset) = p0(s.seg) + s.offset * Point(-sin(α0(s.seg)), cos(α0(s.seg)))
p1(s::ConstantOffset) = p1(s.seg) + s.offset * Point(-sin(α1(s.seg)), cos(α1(s.seg)))
α0(s::ConstantOffset) = α0(s.seg)
α1(s::ConstantOffset) = α1(s.seg)
direction(s::ConstantOffset, t) = direction(s.seg, t)

p0(s::GeneralOffset{T}) where {T} =
    p0(s.seg) + getoffset(s, zero(T)) * Point(-sin(α0(s.seg)), cos(α0(s.seg)))
α0(s::GeneralOffset{T}) where {T} = direction(s, zero(T))
function direction(s::GeneralOffset{T}, t) where {T}
    tang = tangent(s, t)
    return uconvert(°, atan(tang.y, tang.x))
end

function setα0p0!(s::OffsetSegment, angle, p::Point)
    rotation_angle = angle - α0(s)
    rotated_offset = Rotation(rotation_angle)(p0(s) - p0(s.seg))
    return setα0p0!(s.seg, α0(s.seg) + rotation_angle, p - rotated_offset)
end

function change_handedness!(x::ConstantOffset)
    x.offset = -x.offset
    return change_handedness!(x.seg)
end

function change_handedness!(x::GeneralOffset)
    orig_offset = x.offset
    x.offset = (t -> -orig_offset(t))
    return change_handedness!(x.seg)
end

function tangent(s::OffsetSegment, t)
    # calculate derivative w.r.t. s.seg arclength
    # d/dt (s.seg(t) + offset(s, t) * normal(s.seg, t))
    base_dir = direction(s.seg, t)
    base_tangent = Point(cos(base_dir), sin(base_dir))
    base_normal = Point(-base_tangent.y, base_tangent.x)
    doff_ds = offset_derivative(s, t)

    curv = signed_curvature(s.seg, t)
    off_tangent =
        base_tangent + doff_ds * base_normal - getoffset(s, t) * curv * base_tangent
    return off_tangent
end

function signed_curvature(seg::Segment, s)
    return 1 / curvatureradius(seg, s)
end

function _last_curvature(pa::Path{T}) where {T}
    isempty(pa) && return 0.0 / oneunit(T)
    return signed_curvature(pa[end].seg, pathlength(pa[end].seg))
end

function curvatureradius(seg::ConstantOffset, s)
    r = curvatureradius(seg.seg, s) # Ignore offset * dκds term
    return r - getoffset(seg, s)
end

function curvatureradius(seg::GeneralOffset, s)
    # Only approximate for BSpline offsets (ignores offset * dκds term)
    # let s (above argument) be seg.seg arclength, let l be seg arclength
    # g is dseg/ds, defined above as `tangent(seg, s)`
    # ||d^2/dl^2 seg(s)|| = ||d/dl (g ds/dl)||
    # ||(d/ds g) (ds/dl)^2 + g d^2s/dl^2||
    # Where ||ds/dl|| = 1/||g|| = 1 for non-offset segments
    # But needs a correction for offsets
    # dt/ds = κ n # t is tangent, n normal, κ curvature of base curve
    # dn/ds = -κ t
    # ||(κ n + (d2_offset n - κ t d_offset) - d_offset κ t - offset κ^2 n - offset t dκ/ds)(ds/dl)^2 + tangent(seg, s) d^2s/dl^2||

    r = curvatureradius(seg.seg, s)
    ds_dl = 1 / (sqrt((1 - getoffset(seg, s) / r)^2 + offset_derivative(seg, s)^2))
    base_dir = direction(seg.seg, s)
    base_tangent = Point(cos(base_dir), sin(base_dir)) # True for non-offset segments (arclength parameterized)
    base_normal = Point(-base_tangent.y, base_tangent.x)

    d_offset = offset_derivative(seg, s)
    d2_offset = ForwardDiff.derivative(s_ -> offset_derivative(seg, s_), s)
    d2s_dl2 =
        (-1 / 2) *
        ds_dl^3 *
        (
            -2 * (offset_derivative(seg, s) / r) * (1 - getoffset(seg, s) / r) +
            2 * offset_derivative(seg, s) * d2_offset
        )

    d2_seg =
        (
            (1 / r) * base_normal +
            d2_offset * base_normal +
            -2 * (1 / r) * base_tangent * d_offset +
            -((1 / r) * base_normal) * ((1 / r) * getoffset(seg, s))
            #- getoffset(seg, s) * base_tangent * dκds(seg.seg, s) # Nonzero for BSplines but basically fine to ignore
        ) * ds_dl^2 + tangent(seg, s) * d2s_dl2
    return sign(r) / norm(d2_seg)
end

summary(s::OffsetSegment) = summary(s.seg) * " offset by $(s.offset)"

# Methods for creating offset segments
OffsetSegment(seg::S, offset::Coordinate) where {T, S <: Segment{T}} =
    ConstantOffset{T, S}(copy(seg), offset)
OffsetSegment(seg::S, offset) where {T, S <: Segment{T}} =
    GeneralOffset{T, S}(copy(seg), offset)
offset(seg::Segment, s) = OffsetSegment(seg, s)
offset(seg::ConstantOffset, s::Coordinate) = offset(seg.seg, s + seg.offset)
offset(seg::ConstantOffset, s) = offset(seg.seg, t -> s(t) + seg.offset)
offset(seg::GeneralOffset, s::Coordinate) = offset(seg.seg, t -> s + seg.offset(t))
offset(seg::GeneralOffset, s) = offset(seg.seg, t -> s(t) + seg.offset(t))

# Define outer constructors for Turn and Straight from
Straight(x::ConstantOffset{T, Straight{T}}) where {T} =
    Straight{T}(x.seg.l, p0=p0(x), α0=α0(x))
function Turn(x::ConstantOffset{T, Turn{T}}) where {T}
    return Turn(
        x.seg.α,
        x.seg.r + (abs(x.seg.α) > x.seg.α ? x.offset : -x.offset),
        p0=p0(x),
        α0=x.seg.α0
    )
end
# Methods for true length of offset curves
# Note that t parameterization is not necessarily arclength parameterization for BSplines
# (Or for offsets of BSplines)
function check_interval(f, t0, t1)
    valid = (t0 >= 0 && t1 <= 1 && t0 < t1)
    return valid || error(
        "Invalid interval [$t0, $t1] on $f. Interval should be of the form [t0, t1] with 0 <= t0 < t1 <= 1."
    )
end

function arclength(f::Segment, t1::Real=1.0; t0::Real=0.0)
    check_interval(f, t0, t1)
    return pathlength(f) * (min(t1, 1.0) - max(t0, 0.0))
end

function arclength(f::OffsetSegment{T}, t1::Real=1.0; t0::Real=0.0) where {T}
    check_interval(f, t0, t1)
    l_tot = pathlength(f)
    return quadgk(t -> norm(Paths.ForwardDiff.derivative(f, t)), t0 * l_tot, t1 * l_tot)[1]
end

# For underlying BSplines we can calculate the excess length due to curvature directly
function arclength(f::ConstantOffset{T, BSpline{T}}, t1::Real=1.0; t0::Real=0.0) where {T}
    check_interval(f, t0, t1)
    l_orig = arclength(f.seg, t1; t0=t0)
    # Constant offset just changes tangent component of gradient
    # So we can just add the extra contribution due to curvature
    G = StaticArrays.@MVector [zero(Point{T})]
    H = StaticArrays.@MVector [zero(Point{T})]
    l_extra = f.offset * quadgk(t -> _curvature_arclength!(f.seg, G, H, t), t0, t1)[1]
    return l_orig + l_extra
end

# For general offsets we also have to add the contribution from varying offset
function arclength(f::GeneralOffset{T, BSpline{T}}, t1::Real=1.0; t0::Real=0.0) where {T}
    check_interval(f, t0, t1)
    G = StaticArrays.@MVector [zero(Point{T})]
    H = StaticArrays.@MVector [zero(Point{T})]
    # Each offset segment will have length (sqrt(s′^2 +x^2) ds)
    # where x is the derivative of the offset (normal component of arclength)
    # and s′ is the curvature*offset contribution (tangent arclength)
    l = quadgk(
        t ->
            sqrt(
                (
                    1 -
                    _curvature!(f.seg, G, H, t) * getoffset(f, t_to_arclength(f.seg, t))
                )^2 + (offset_derivative(f, t_to_arclength(f.seg, t)))^2
            ) * dsdt(t, f.seg.r),
        t0,
        t1
    )[1]
    return l
end

function _curvature_arclength!(b::BSpline, G, H, t)
    # Curvature for arbitrary parameterization divides by another norm(g)
    # (and has opposite sign)
    # But when integrating over arclength we need to multiply by norm(g)
    Paths.Interpolations.gradient!(G, b.r, t)
    Paths.Interpolations.hessian!(H, b.r, t)
    return uconvert(NoUnits, (G[1].y * H[1].x - G[1].x * H[1].y) / norm(G[1])^2)
end

function _curvature!(b::BSpline, G, H, t)
    Paths.Interpolations.gradient!(G, b.r, t)
    Paths.Interpolations.hessian!(H, b.r, t)
    return uconvert(NoUnits, (G[1].x * H[1].y - G[1].y * H[1].x) / norm(G[1])^2) /
           norm(G[1])
end

function _split(seg::ConstantOffset, x)
    segs = split(seg.seg, x)
    return offset(segs[1], seg.offset), offset(segs[2], seg.offset)
end

function _split(seg::GeneralOffset, x)
    segs = split(seg.seg, x)
    return offset(segs[1], seg.offset), offset(segs[2], t -> seg.offset(t + x))
end
