# Define paths with spline interpolations
# Allows specifying only start/end points and tangents
# Might consider something that only uses straights and circular arcs (for ease of rendering)

import Interpolations
import Interpolations: prefiltering_system, Cubic, OnGrid, interpolate
import QuadGK: quadgk
import ForwardDiff: Dual, partials, value, Partials
using LinearAlgebra

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
    r::Paths.Interpolations.AbstractInterpolation{Point{T}} # function of t between 0 and 1
    p0
    p1
    α0::typeof(1.0°)
    α1::typeof(1.0°)
    function BSpline{T}(p::Vector{Point{T}}, t0::Point{T}, t1::Point{T}) where {T}
        # don't check against AbstractFloat since Quantity{<:AbstractFloat} !<: AbstractFloat
        float(T) <: T || error("expecting a numeric float type.")
        r = Interpolations.scale(
            interpolate(p, Interpolations.BSpline(Cubic(NeumannBC(t0, t1)))),
            range(0.0, stop=1.0, length=length(p))
        )
        return new{T}(p, t0, t1, r, p[1], p[end], atan(t0[2], t0[1]), atan(t1[2], t1[1]))
    end
    function BSpline{T}(p, t0, t1, r, p0, p1, α0, α1) where {T}
        # don't check against AbstractFloat since Quantity{<:AbstractFloat} !<: AbstractFloat
        float(T) <: T || error("expecting a numeric float type.")
        return new{T}(p, t0, t1, r, p0, p1, α0, α1)
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
function _update_interpolation!(b::BSpline)
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

pathlength(b::BSpline) = t_to_arclength(b, 1.0)

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

function arclength_to_t(b::BSpline{T}, s1) where {T}
    # minimize f(t) = (s(t) - s1)^2
    # dfdt = abs(grad(b.r(t))) * 2*(s(t) - s1)
    u = pathlength(b)
    t0 = [ustrip(NoUnits, s1 / u)]
    function f(t)
        out = ((t_to_arclength(b, t[1]) - s1)^2) / u^2
        ((t[1] < 0.0) || (t[1] > 1.0)) && (out = Inf) # the optimizer may find (t<0) or (t>1) unless we add hard walls to the optimization
        return out
    end
    g!(G, t) = begin
        G[1] = (dsdt(t[1], b.r) * 2 * (t_to_arclength(b, t[1]) - s1)) / u^2
    end
    return Optim.minimizer(optimize(f, g!, t0))[1]
end

function t_to_arclength(b::BSpline{T}, t1::Real) where {T}
    if t1 > 1.0
        return pathlength(b)
    elseif t1 <= 0.0
        return zero(T)
    end

    (I, E) = quadgk(t -> dsdt(t, b.r), zero(t1), t1)
    return I
end

function arclength(b::BSpline{T}, t1::Real=1.0; t0::Real=0.0) where {T}
    t0 = max(t0, 0.0)
    t1 = min(t1, 1.0)

    (I, E) = quadgk(t -> dsdt(t, b.r), t0, t1)
    return I
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
    bspline!(p::Path{T}, nextpoints, α_end, sty::Style=contstyle1(p), endpoints_speed=2500μm)

Add a BSpline interpolation from the current endpoint of `p` through `nextpoints`.

The interpolation reaches `nextpoints[end]` making the angle `α_end` with the positive x-axis.
The `endpoints_speed` is "how fast" the interpolation leaves and enters its endpoints. Higher
speed means that the start and end angles are approximately α1(p) and α_end over a longer
distance.
"""
function bspline!(
    p::Path{T},
    nextpoints,
    α_end,
    sty::Style=contstyle1(p);
    endpoints_speed=2500.0 * DeviceLayout.onemicron(T),
    kwargs...
) where {T}
    !isempty(p) &&
        (segment(last(p)) isa Paths.Corner) &&
        error("`Paths.Straight` segments must follow `Paths.Corner`s.")
    ps = [p1(p)]
    append!(ps, nextpoints)
    endpoints_speed = endpoints_speed * 1 / (length(ps) - 1) # From scaling interpolation from i=1:length(ps) => t=0..1
    t0 = endpoints_speed * Point(cos(α1(p)), sin(α1(p)))
    t1 = endpoints_speed * Point(cos(α_end), sin(α_end))
    seg = BSpline(ps, t0, t1)
    push!(p, Node(seg, convert(ContinuousStyle, sty)))
    return nothing
end

# Patch in new boundary condition for Interpolations.jl allowing us to specify derivative
struct NeumannBC{GT <: Interpolations.GridType} <: Interpolations.BoundaryCondition
    gt::GT
    g0
    g1
end
NeumannBC(g0, g1) = NeumannBC(Interpolations.OnGrid(), g0, g1)

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
    degree::Cubic{NeumannBC{Interpolations.OnGrid}}
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
