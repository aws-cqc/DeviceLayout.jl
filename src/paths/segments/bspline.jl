# Define paths with spline interpolations
# Allows specifying only start/end points and tangents
# Might consider something that only uses straights and circular arcs (for ease of rendering)

import Interpolations
import Interpolations: prefiltering_system, Cubic, OnGrid, interpolate
import QuadGK: quadgk
import ForwardDiff: Dual, partials, value, Partials
using LinearAlgebra

# Patch in new boundary condition for Interpolations.jl allowing us to specify derivative
struct NeumannBC{GT <: Interpolations.GridType, T} <: Interpolations.BoundaryCondition
    gt::GT
    g0::T
    g1::T
end
NeumannBC(g0, g1) = NeumannBC(Interpolations.OnGrid(), g0, g1)

# Concrete type of interpolation, only used in BSpline struct definition
const LayoutBSplineItp{T} = Interpolations.ScaledInterpolation{
    Point{T},
    1,
    Interpolations.BSplineInterpolation{
        Point{T},
        1,
        Interpolations.OffsetArrays.OffsetVector{Point{T}, Vector{Point{T}}},
        Interpolations.BSpline{
            Interpolations.Cubic{NeumannBC{Interpolations.OnGrid, Point{T}}}
        },
        Tuple{Base.OneTo{Int64}}
    },
    Interpolations.BSpline{
        Interpolations.Cubic{NeumannBC{Interpolations.OnGrid, Point{T}}}
    },
    Tuple{
        StepRangeLen{
            Float64,
            Base.TwicePrecision{Float64},
            Base.TwicePrecision{Float64},
            Int64
        }
    }
}

"""
    struct BSplineReparam{T}

Cached arc-length reparameterization of a [`BSpline`](@ref).

`ss[i]` is the exact arclength from `t = 0` to `t = ts[i]`, with `ts[1] == 0`,
`ts[end] == 1`, and `total == ss[end] == pathlength`. Used to make `pathlength`,
`t_to_arclength`, and `arclength_to_t` cheap without changing their values
(within tolerance). The forward map stays exact, using an incremental integral
seeded by the table, and the inverse is Newton's method on that same map.

Derived entirely from the interpolation `r`, so it is excluded from `==`/`hash`
and reset to `nothing` whenever `r` is rebuilt (see `_update_interpolation!`).
"""
struct BSplineReparam{T}
    ts::Vector{Float64}
    ss::Vector{T}
    total::T
end

"""
    mutable struct BSpline{T} <: ContinuousSegment{T}

Interpolate between points `p` with start and end tangents `t0`, `t1`.

Computes the interpolated coordinate `r(t)` as a function of a dimensionless
parameter `t`, using b-spline interpolation `knots` spaced uniformly in `t`.
That is, `r(0) == p[1]` and `r(1) == p[end]`, and generally `r((i-1)*tinc) == p[i]`
where `tinc` is the knot value spacing `1/(length(p)-1)`.

A `BSpline` instance itself can be called as a parametric function of
a length that ranges from zero to the total path length.
"""
mutable struct BSpline{T} <: ContinuousSegment{T}
    p::Vector{Point{T}}
    t0::Point{T}
    t1::Point{T}
    r::LayoutBSplineItp{T} # function of t between 0 and 1
    p0::Point{T}
    p1::Point{T}
    α0::typeof(1.0°)
    α1::typeof(1.0°)
    reparam::Union{Nothing, BSplineReparam{T}} # lazily built arclength cache; see BSplineReparam
    function BSpline{T}(p::Vector{Point{T}}, t0::Point{T}, t1::Point{T}) where {T}
        # don't check against AbstractFloat since Quantity{<:AbstractFloat} !<: AbstractFloat
        float(T) <: T || error("expecting a numeric float type.")
        r = Interpolations.scale(
            interpolate(p, Interpolations.BSpline(Cubic(NeumannBC(t0, t1)))),
            range(0.0, stop=1.0, length=length(p))
        )
        return new{T}(
            p,
            t0,
            t1,
            r,
            p[1],
            p[end],
            atan(t0[2], t0[1]),
            atan(t1[2], t1[1]),
            nothing
        )
    end
    function BSpline{T}(p, t0, t1, r, p0, p1, α0, α1) where {T}
        # don't check against AbstractFloat since Quantity{<:AbstractFloat} !<: AbstractFloat
        float(T) <: T || error("expecting a numeric float type.")
        return new{T}(p, t0, t1, r, p0, p1, α0, α1, nothing)
    end
end

"""
    BSpline(p::Vector{Point{T}}, t0::Point, t1::Point) where {T}

Outer constructor for `BSpline` segments.
"""
function BSpline(p::Vector{Point{T}}, t0::Point, t1::Point) where {T}
    S = float(T)
    PS = Point{S}
    return BSpline{S}(convert(Vector{PS}, p), convert(PS, t0), convert(PS, t1))
end

BSpline(p::Vector{Point{T}}, t0::Point{T}, t1::Point{T}, r, p0, p1, α0, α1) where {T} =
    BSpline{T}(p, t0, t1, r, p0, p1, α0, α1)

# `reparam` is intentionally excluded: it is derived from the fields below, so two
# splines that are equal in those fields are equal regardless of whether either has
# built its cache. (Same reasoning as `r`, which follows from `p`, `t0`, `t1`.)
function Base.:(==)(b1::BSpline, b2::BSpline)
    return b1.p == b2.p &&
           b1.t0 == b2.t0 &&
           b1.t1 == b2.t1 &&
           b1.r == b2.r &&
           b1.p0 == b2.p0 &&
           b1.p1 == b2.p1 &&
           b1.α0 % 360° == b2.α0 % 360° &&
           b1.α1 % 360° == b2.α1 % 360°
end

function Base.hash(b::BSpline, h::UInt)
    um = unit(DeviceLayout.onemicron(b.p0.x))
    h = hash(BSpline, h)
    h = hash(1um, h) # Unitful and unitless turns are not equal
    h = hash(ustrip(um, b.p), h)
    h = hash(ustrip(um, b.t0), h) # Workaround Unitful.jl issue #379
    h = hash(ustrip(um, b.t1), h) # Same segment hash for different units
    # h = hash(b.r, h) # Hashes for AbstractInterpolation are different even when b1.r == b2.r
    # But b.r follows from everything else, including scaling which is captured in p0, p1
    # ... as long as _update_interpolation! has been called
    # So we hash the parts of r that can vary
    # (b.reparam is likewise derived from b.r and deliberately not hashed)
    h = hash(b.r.ranges, h)
    h = hash(b.r.itp.it, h)
    h = hash(ustrip(um, b.r.itp.coefs), h)
    h = hash(b.r.itp.parentaxes, h)
    h = hash(ustrip(um, b.p0), h)
    h = hash(ustrip(um, b.p1), h)
    h = hash(b.α0 % 360°, h)
    return hash(b.α1 % 360°, h)
end

"""
    (b::BSpline)(s)

Return the point an arclength `s` along the spline.

For `s` greater than the total spline arclength or less than zero by some
excess `Δs`, the returned point is extrapolated beyond the start or end of the
path by `Δs` along the start or end tangent.
"""
function (b::BSpline)(s)
    if s >= pathlength(b)
        return p1(b) + (s - pathlength(b)) * (b.t1 / norm(b.t1))
    end
    if s <= zero(s)
        return p0(b) + s * (b.t0 / norm(b.t0))
    end
    return b.r(arclength_to_t(b, s))
end

"""
    setp0!(b::BSpline, p::Point)

Translate the interpolated segment so its initial point is `p`.
"""
function setp0!(b::BSpline, p::Point)
    # Adjust interpolation points
    translate = Translation(p - p0(b))
    b.p .= translate.(b.p)

    return _update_interpolation!(b)
end

"""
    setα0!(b::BSpline, α0′)

Set the starting angle of an interpolated segment.
"""
setα0!(b::BSpline, α0′) = begin
    # Adjust interpolation points
    rotate = Rotation(α0′ - α0(b))
    rotate_interp = Translation(p0(b)) ∘ rotate ∘ Translation(-p0(b))
    b.p .= rotate_interp.(b.p)

    # Adjust tangents
    b.t0 = rotate(b.t0)
    b.t1 = rotate(b.t1)
    # Effective initial and final angles at 0 and 1
    dα = (α0′ - α0(b))
    b.α0 = α0(b) + dα
    b.α1 = α1(b) + dα

    _update_interpolation!(b)
end

"""
    change_handedness!(b::BSpline)

Change the "handedness" of `b` by reflecting across the tangent at the start point.
"""
function change_handedness!(b::BSpline)
    # Perform reflection of points across line
    axis_dir = Point(cos(α0(b)), sin(α0(b)))
    refl = Reflection(axis_dir)
    # Adjust tangents
    b.t0 = refl(b.t0)
    b.t1 = refl(b.t1)
    b.p = Reflection(axis_dir; through_pt=p0(b)).(b.p)

    # Effective final angle at 0 and 1
    b.α0 = rotated_direction(b.α0, refl)
    b.α1 = rotated_direction(b.α1, refl)

    return _update_interpolation!(b)
end

"""
    _update_interpolation!(b::BSpline)

Reconcile the interpolation `b.r` with possible changes to `b.p`, `b.t0`, `b.t1`.

Also updates `b.p0`, `b.p1`.
"""
function _update_interpolation!(b::BSpline{T}) where {T}
    # Use true t range for interpolations defined by points that have been scaled out of [0,1]
    tmin = b.r.ranges[1][1]
    tmax = b.r.ranges[1][end]

    # Recalculate the interpolation function
    b.r = Interpolations.scale(
        interpolate(b.p, Interpolations.BSpline(Cubic(NeumannBC(b.t0, b.t1)))),
        range(tmin, stop=tmax, length=length(b.p))
    )

    # Effective start and end points at 0 and 1
    b.p0 = b.r(0.0)
    b.p1 = b.r(1.0)

    # The arclength cache is derived from `r`, which we just rebuilt; drop it so the
    # next arclength query rebuilds it. This is the single choke point for `r` changes.
    b.reparam = nothing
    return
end

convert(::Type{BSpline{T}}, x::BSpline{T}) where {T} = x
function convert(::Type{BSpline{T}}, b::BSpline{S}) where {T, S}
    # Use true t range for interpolations defined by points that have been scaled out of [0,1]
    tmin = b.r.ranges[1][1]
    tmax = b.r.ranges[1][end]
    p = convert.(Point{T}, b.p)
    t0 = convert(Point{T}, b.t0)
    t1 = convert(Point{T}, b.t1)
    p0 = convert(Point{T}, b.p0)
    p1 = convert(Point{T}, b.p1)
    r = Interpolations.scale(
        interpolate(p, Interpolations.BSpline(Cubic(NeumannBC(t0, t1)))),
        range(tmin, stop=tmax, length=length(p))
    )
    return BSpline(p, t0, t1, r, p0, p1, b.α0, b.α1)
end
convert(::Type{Segment{T}}, x::BSpline) where {T} = convert(BSpline{T}, x)
copy(b::BSpline) = BSpline(copy(b.p), b.t0, b.t1, b.r, b.p0, b.p1, b.α0, b.α1)

p0(b::BSpline) = b.p0
p1(b::BSpline) = b.p1

α0(b::BSpline) = b.α0
α1(b::BSpline) = b.α1

function direction(b::BSpline, s)
    ds = s / pathlength(b)
    if ds >= 1
        return α1(b)
    elseif ds <= 0
        return α0(b)
    end
    g_s = Interpolations.gradient(b.r, arclength_to_t(b, s))[1]
    return atan(g_s.y, g_s.x)
end

function direction(
    b::BSpline,
    s::Unitful.Quantity{Dual{S, V, P}, D, U}
) where {S, V, P, D, U}
    us = unit(s)
    s_ = ustrip(s)
    t0 = arclength_to_t(b, us * value(s_))
    d0 = direction(b, us * value(s_))
    g_s = Interpolations.gradient(b.r, t0)[1]
    h_s = Interpolations.hessian(b.r, t0)[1]

    p =
        partials(s_) *
        us *
        (1 / (g_s.x^2 + g_s.y^2)) *
        (h_s.y * g_s.x - h_s.x * g_s.y) *
        dtds(t0, b.r)
    up = unit(p[1])
    p_ = ustrip(p[1])
    return Dual{S}(d0, p_...) * up
end

pathlength(b::BSpline) = _get_reparam(b).total

function pathlength_nearest(seg::Paths.BSpline{T}, pt::Point) where {T}
    errfunc(s) = ustrip(norm(seg.r(s) - pt))
    t_nearest = Optim.minimizer(optimize(errfunc, 0.0, 1.0))[1]
    return t_to_arclength(seg, t_nearest)
end

function _split(seg::BSpline{T}, x) where {T}
    t = arclength_to_t(seg, x)

    # Use true t range for interpolations defined by points that have been scaled out of [0,1]
    tmin = seg.r.ranges[1][1]
    tmax = seg.r.ranges[1][end]

    # Expand the first interval symmetrically around 0
    s1 = Interpolations.scale(
        seg.r.itp,
        range(tmin / t, stop=tmax / t, length=length(seg.p))
    ) # t'=0:1 equiv to 0:t
    # Expand the second interval symmetrically around 1: t' = (t-1)/(1-t_split) + 1 = (t-t_split)/(1-t_split)
    s2 = Interpolations.scale(
        seg.r.itp,
        range((tmin - t) / (1 - t), stop=(tmax - t) / (1 - t), length=length(seg.p))
    ) # t'=0:1 equiv to t:1
    # "End tangents" t0, t1 will be the same since they apply to the endpoints of the whole interpolation
    # But α0, α1 must come from t=0 and t=1 for each new segment
    α10 = α0(seg)
    α11 = direction(seg, x)
    α20 = α11
    α21 = α1(seg)
    # Likewise p0, p1
    p10 = p0(seg)
    p11 = seg(x)
    p20 = p11
    p21 = p1(seg)

    return BSpline(copy(seg.p), seg.t0, seg.t1, s1, p10, p11, α10, α11),
    BSpline(copy(seg.p), seg.t0, seg.t1, s2, p20, p21, α20, α21)
end

# Base grid resolution for the arclength cache. Nodes = max(NMIN, NPERSPAN*spans + 1),
# where `spans = length(p) - 1` is the number of knot intervals (where dsdt varies).
# The forward map stays exact regardless of N (see `t_to_arclength`), so N only affects
# the one-time build cost and the Newton seed quality; kept small to keep the first
# arclength query on a near-straight spline close to a single old `pathlength` call.
const _REPARAM_NMIN = 9
const _REPARAM_NPERSPAN = 4

function _build_reparam(b::BSpline{T}) where {T}
    N = max(_REPARAM_NMIN, _REPARAM_NPERSPAN * (length(b.p) - 1) + 1)
    ts = collect(range(0.0, stop=1.0, length=N))
    ss = Vector{T}(undef, N)
    ss[1] = zero(T)
    # Incremental exact integration: partitioning [0,1] and summing is at least as
    # accurate as one quadgk over the whole range (dsdt >= 0, so ss is nondecreasing).
    for i = 2:N
        (I, _) = quadgk(t -> dsdt(t, b.r), ts[i - 1], ts[i])
        ss[i] = ss[i - 1] + I
    end
    return BSplineReparam{T}(ts, ss, ss[end])
end

# Lazily build and cache the reparameterization. Benign under races: BSplineReparam is
# immutable and deterministic, so a concurrent double-build just discards one identical copy.
function _get_reparam(b::BSpline{T}) where {T}
    isnothing(b.reparam) && (b.reparam = _build_reparam(b))
    return b.reparam
end

function arclength_to_t(b::BSpline{T}, s1) where {T}
    rp = _get_reparam(b)
    L = rp.total
    s1 <= zero(s1) && return 0.0
    s1 >= L && return 1.0
    # Seed with the linear inverse of the (ss, ts) table: locate the bracketing panel
    # and interpolate within it. `s1 < L` guarantees j <= N-1.
    j = clamp(searchsortedlast(rp.ss, s1), 1, length(rp.ss) - 1)
    tlo, thi = rp.ts[j], rp.ts[j + 1]
    t = tlo + (thi - tlo) * ustrip(NoUnits, (s1 - rp.ss[j]) / (rp.ss[j + 1] - rp.ss[j]))
    # Hybrid Newton/bisection on the exact forward map s(t): monotone, so the root is
    # bracketed by [tlo, thi] and bisection is always a safe fallback.
    for _ = 1:12
        f = t_to_arclength(b, t) - s1
        (f > zero(f)) ? (thi = t) : (tlo = t)
        abs(ustrip(NoUnits, f / L)) <= 1e-12 && return t
        deriv = dsdt(t, b.r)
        tnew = iszero(deriv) ? (tlo + thi) / 2 : t - f / deriv
        # Fall back to bisection if Newton leaves the bracket (near an inflection of s(t))
        (tnew <= tlo || tnew >= thi) && (tnew = (tlo + thi) / 2)
        abs(tnew - t) <= 1e-13 && return tnew
        t = tnew
    end
    return t
end

function t_to_arclength(b::BSpline{T}, t1::Real) where {T}
    rp = _get_reparam(b)
    t1 > 1.0 && return rp.total
    t1 <= 0.0 && return zero(T)
    # Exact: cumulative arclength to the nearest node below t1, plus the residual integral
    # over a panel no wider than one grid step.
    i = clamp(searchsortedlast(rp.ts, t1), 1, length(rp.ts) - 1)
    (I, _) = quadgk(t -> dsdt(t, b.r), rp.ts[i], t1)
    return rp.ss[i] + I
end

function arclength(b::BSpline{T}, t1::Real=1.0; t0::Real=0.0) where {T}
    t0 = max(t0, 0.0)
    t1 = min(t1, 1.0)

    # Common case t0 == 0: reuse the cached forward map (exact) instead of a fresh quadgk.
    iszero(t0) && return t_to_arclength(b, t1)

    (I, E) = quadgk(t -> dsdt(t, b.r), t0, t1)
    return I
end

function discretization(
    seg::BSpline{T};
    atol=DeviceLayout.onenanometer(T),
    rtol=nothing,
    kwargs...
) where {T}
    return [
        t_to_arclength(seg, t) for
        t in DeviceLayout.discretization_grid(seg, atol; rtol=rtol)
    ]
end

function dtds(t, r)
    if t < 0 || t > 1
        return 0.0
    end
    return 1.0 / LinearAlgebra.norm(Interpolations.gradient(r, t)[1])
end

function dsdt(t, r)
    if t < 0 || t > 1
        return 0.0 * Unitful.unit(LinearAlgebra.norm(r(0.0)))
    end
    return LinearAlgebra.norm(Interpolations.gradient(r, t)[1])
end

# positive curvature radius is a left handed turn, negative right handed.
function curvatureradius(b::BSpline{T}, s) where {T}
    t = clamp(arclength_to_t(b, s), 0.0, 1.0)
    g = Interpolations.gradient(b.r, t)[1]
    h = Interpolations.hessian(b.r, t)[1]
    return (g[1]^2 + g[2]^2)^(3 // 2) / (g[1] * h[2] - g[2] * h[1])
end

"""
    bspline!(p::Path{T}, nextpoints, α_end, sty::Style=nextstyle(p);
        endpoints_speed=2500.0 * DeviceLayout.onemicron(T),
        endpoints_curvature=nothing,
        auto_speed=false,
        auto_curvature=false,
        kwargs...)

Add a BSpline interpolation from the current endpoint of `p` through `nextpoints`.

The interpolation reaches `nextpoints[end]` making the angle `α_end` with the positive x-axis.
The `endpoints_speed` is "how fast" the interpolation leaves and enters its endpoints. Higher
speed means that the start and end angles are approximately `α1(p)` and `α_end` over a longer
distance.

If `auto_speed` is `true`, then `endpoints_speed` is ignored. Instead, the
endpoint speeds are optimized to make curvature changes gradual as possible
(minimizing the integrated square of the curvature derivative with respect
to arclength).

If `endpoints_curvature` (dimensions of `oneunit(T)^-1`) is specified, then
additional waypoints are placed so that the curvature at the endpoints is equal to
`endpoints_curvature`.

If `auto_curvature` is specified, then `endpoints_curvature` is ignored.
Instead, the curvature at the end of the previous segment of the path is used, or
zero curvature if the path was empty.

`endpoints_speed` and `endpoints_curvature` can also be provided as 2-element
iterables to specify initial and final boundary conditions separately.
"""
function bspline!(
    p::Path{T},
    nextpoints,
    α_end,
    sty::Style=nextstyle(p);
    endpoints_speed=2500.0 * DeviceLayout.onemicron(T),
    endpoints_curvature=nothing,
    auto_speed=false,
    auto_curvature=false,
    kwargs...
) where {T}
    !isempty(p) &&
        (segment(last(p)) isa Paths.Corner) &&
        error("`Paths.Straight` segments must follow `Paths.Corner`s.")
    ps = [p1(p)]
    append!(ps, nextpoints)
    tangent_scale = 1 / (length(ps) - 1) # From scaling interpolation from i=1:length(ps) => t=0..1
    t0, t1 = _bspline_tangents(tangent_scale, α1(p), α_end, endpoints_speed)
    seg = BSpline(ps, t0, t1)
    auto_curvature && (endpoints_curvature = _last_curvature(p))
    if auto_speed
        seg.t0 = Point(cos(α0(seg)), sin(α0(seg))) * norm(seg.p[2] - seg.p[1])
        seg.t1 = Point(cos(α1(seg)), sin(α1(seg))) * norm(seg.p[end] - seg.p[end - 1])
        _set_endpoints_curvature!(seg, endpoints_curvature, add_points=true)
        _optimize_bspline!(seg; endpoints_curvature)
    elseif !isnothing(endpoints_curvature)
        _set_endpoints_curvature!(seg, endpoints_curvature, add_points=true)
        _update_interpolation!(seg)
    end
    push!(p, Node(seg, convert(ContinuousStyle, sty)))
    return nothing
end

_bspline_tangents(scale, dir0, dir1, speed0speed1) =
    _bspline_tangents(scale, dir0, dir1, first(speed0speed1), last(speed0speed1))

function _bspline_tangents(scale, dir0, dir1, speed0::Coordinate, speed1=speed0)
    t0 = scale * speed0 * Point(cos(dir0), sin(dir0))
    t1 = scale * speed1 * Point(cos(dir1), sin(dir1))
    return t0, t1
end

"""
`Cubic{NeumannBC}` `OnGrid` amounts to setting `y_1'(x) = g0` at `x = 0`
and  `y_n'(x) = g1` at `x = 1`.
Applying this condition yields

    -1/2 cm + 1/2 cp = g0 (i=1)
    -1/2 c + 1/2 cpp = g1 (i=n)
"""
function prefiltering_system(
    ::Type{T},
    ::Type{TC},
    n::Int,
    degree::Cubic{<:NeumannBC{Interpolations.OnGrid}}
) where {T, TC}
    dl, d, du = Interpolations.inner_system_diags(T, n, degree)
    d[1] = -oneunit(T) / 2
    d[end] = oneunit(T) / 2
    du[1] = dl[end] = zero(T)

    # Now Woodbury correction to set `[1, 3], [n, n-2] ==> 1/2, -1/2`
    specs = Interpolations.WoodburyMatrices.sparse_factors(
        T,
        n,
        (1, 3, oneunit(T) / 2),
        (n, n - 2, -oneunit(T) / 2)
    )
    b = zeros(TC, n)
    b[1] = degree.bc.g0
    b[end] = degree.bc.g1
    return Interpolations.Woodbury(Interpolations.lut!(dl, d, du), specs...), b
end

# This is debatable but it is what was being called in Interpolations v0.13.0 and below.
Interpolations.tweight(A::AbstractArray{<:Point}) = Float64
