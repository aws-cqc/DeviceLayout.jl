"""
    discretize_curve(f, ddf, tolerance; rtol=nothing, t_scale=1.0)

Given a curve `f` and its second derivative `ddf`, discretize a curve into piecewise linear segments with an approximate absolute tolerance.

If `rtol` is provided, the effective tolerance at each step is `max(tolerance, rtol / curvature)`, i.e. `rtol * radius_of_curvature`. This allows coarser discretization on gentle curves while preserving accuracy on tight ones.

`t_scale` converts parameter-space steps to arclength for the kernel's chord-height formula. When `ddf` has curvature units (1/length), pass `t_scale = pathlength(curve)`.
"""
function discretize_curve(f, ddf, tolerance; rtol=nothing, t_scale=1.0)
    ts = discretization_grid(ddf, tolerance; rtol=rtol, t_scale=t_scale)
    return f.(ts)
end

function discretize_curve(s::Paths.Segment, tolerance; rtol=nothing)
    return s.(discretization_grid(s, tolerance; rtol=rtol) * pathlength(s))
end

function discretize_curve(s::Paths.BSpline, tolerance; rtol=nothing)
    return s.r.(discretization_grid(s, tolerance; rtol=rtol))
end

function discretize_curve(
    s::Paths.ConstantOffset{T, <:Paths.BSpline{T}},
    tolerance;
    rtol=nothing
) where {T}
    return _offset_bspline_point.(Ref(s), discretization_grid(s, tolerance; rtol=rtol))
end

function discretize_curve(
    s::Paths.GeneralOffset{T, <:Paths.BSpline{T}},
    tolerance;
    rtol=nothing
) where {T}
    return _offset_bspline_point.(Ref(s), discretization_grid(s, tolerance; rtol=rtol))
end

function discretize_curve(s::Paths.Turn, tolerance; rtol=nothing)
    if !isnothing(rtol)
        tolerance = max(tolerance, rtol * abs(s.r))
    end
    θ_0 = s.α0 - sign(s.r) * sign(s.α) * 90.0°
    ps = circular_arc(
        θ_0 + sign(s.r) * s.α,
        abs(s.r),
        tolerance;
        θ_0=θ_0,
        center=Paths.curvaturecenter(s)
    )
    length(ps) < 2 && return [p0(s), p1(s)]
    # Avoid floating point disagreement about endpoints compared to evaluating s(x)
    ps[1] = p0(s)
    ps[end] = p1(s)
    return ps
end

function discretize_curve(
    s::Paths.ConstantOffset{T, Paths.Turn{T}},
    tolerance;
    rtol=nothing
) where {T}
    ps = discretize_curve(Paths.resolve_offset(s), tolerance; rtol)
    # Avoid floating point disagreement about endpoints compared to evaluating s(x)
    ps[1] = p0(s)
    ps[end] = p1(s)
    return ps
end

function discretization_grid(s::Paths.Segment, tolerance; rtol=nothing)
    l = pathlength(s)
    return discretization_grid(
        t -> Paths.signed_curvature(s, t * l),
        tolerance;
        t_scale=l,
        rtol=rtol
    )
end

# ConstantOffset segments are parameterized by the base curve's arclength, but
# the actual arclength per unit parameter is |1 - offset * κ_base(t)|. The generic
# Segment method uses pathlength(s) as t_scale, which equals the *base* curve's
# length, not the offset curve's actual arclength. This underestimates t_scale for
# outer offsets and overestimates for inner offsets, causing the chord-height tolerance
# to be violated.
# TODO: For varying base curvature, a single t_scale is only an approximation.
# A fully correct approach would incorporate local curve speed into the marching kernel.
function discretization_grid(s::Paths.ConstantOffset, tolerance; rtol=nothing)
    l = pathlength(s)
    # Exact for constant-curvature base curves like Turn.
    κ_base_start = Paths.signed_curvature(s.seg, zero(l))
    κ_base_end = Paths.signed_curvature(s.seg, l)
    max_speed = max(abs(1 - s.offset * κ_base_start), abs(1 - s.offset * κ_base_end))
    actual_l = l * max_speed
    return discretization_grid(
        t -> Paths.signed_curvature(s, t * l),
        tolerance;
        t_scale=actual_l,
        rtol=rtol
    )
end

# True curvature κ(t) = |r'×r''|/|r'|³ for a 2D BSpline interpolation r.
# Returns a scalar with units 1/length, matching the marching kernel's
# `cc` contract.
# Bypasses arclength-to-t conversion we'd get using `Paths.curvatureradius`/`Paths.signed_curvature`
# Doesn't use pre-allocated G, H as with `Paths._curvature!` -- only minor speedup in some cases anyway
function _bspline_curvature(r, t)
    return abs(_bspline_signed_curvature(r, t))
end

function discretization_grid(s::Paths.BSpline, tolerance; rtol=nothing)
    # Use true curvature κ = |r'×r''|/|r'|³ (units: 1/length) as the kernel's
    # `cc`, so the kernel's rtol/cc formula is dimensionally correct.
    # `t_scale = pathlength(s)` because true curvature is parameterization-free;
    # the kernel converts `t`-steps to length-steps via `t_scale`. Under the
    # standard ds/dt ≈ L approximation (BSplines are not arclength-
    # parameterized) this algebraically matches Hessian-based step size.
    l = pathlength(s)
    return discretization_grid(
        t -> _bspline_curvature(s.r, t),
        tolerance;
        t_scale=l,
        rtol=rtol
    )
end

# Estimate offset-curve length from endpoint speeds to avoid integrating
# Paths.arclength(::OffsetSegment{<:BSpline}) during discretization.
function discretization_grid(
    s::Paths.ConstantOffset{T, <:Paths.BSpline{T}},
    tolerance;
    rtol=nothing
) where {T}
    l = pathlength(s) # base curve length
    κ0 = _bspline_signed_curvature(s.seg.r, 0.0)
    κ1 = _bspline_signed_curvature(s.seg.r, 1.0)
    max_speed = max(abs(1 - s.offset * κ0), abs(1 - s.offset * κ1))
    return discretization_grid(
        t -> _offset_bspline_curvature(s, t),
        tolerance;
        t_scale=l * max_speed,
        rtol=rtol
    )
end

function discretization_grid(
    s::Paths.GeneralOffset{T, <:Paths.BSpline{T}},
    tolerance;
    rtol=nothing
) where {T}
    l = pathlength(s) # base curve length
    κ0 = _bspline_signed_curvature(s.seg.r, 0.0)
    κ1 = _bspline_signed_curvature(s.seg.r, 1.0)
    # The offset' term is the normal-direction contribution absent for constant offsets.
    speed0 = sqrt(
        (1 - Paths.getoffset(s, zero(l)) * κ0)^2 + Paths.offset_derivative(s, zero(l))^2
    )
    speed1 = sqrt((1 - Paths.getoffset(s, l) * κ1)^2 + Paths.offset_derivative(s, l)^2)
    return discretization_grid(
        t -> _offset_bspline_curvature(s, t),
        tolerance;
        t_scale=l * max(speed0, speed1),
        rtol=rtol
    )
end

function _bspline_signed_curvature(r, t)
    g = Paths.Interpolations.gradient(r, t)[1]
    h = Paths.Interpolations.hessian(r, t)[1]
    return (g.x * h.y - g.y * h.x) / (g.x^2 + g.y^2)^(3 // 2)
end

function _offset_bspline_point(s::Paths.ConstantOffset, t)
    g = Paths.Interpolations.gradient(s.seg.r, t)[1]
    tangent = g / norm(g)
    return s.seg.r(t) + s.offset * Point(-tangent.y, tangent.x)
end

function _offset_bspline_point(s::Paths.GeneralOffset, t)
    g = Paths.Interpolations.gradient(s.seg.r, t)[1]
    tangent = g / norm(g)
    l = Paths.t_to_arclength(s.seg, t)
    return s.seg.r(t) + Paths.getoffset(s, l) * Point(-tangent.y, tangent.x)
end

# Offset-BSpline curvature in base spline `t` space, avoiding an arclength-to-`t`
# root-find at every discretization step.
function _offset_bspline_curvature(s::Paths.ConstantOffset, t)
    κ = _bspline_signed_curvature(s.seg.r, t)
    return abs(κ) / abs(1 - s.offset * κ)
end

# Mirrors curvatureradius(::GeneralOffset, s), including its ignored offset*dκ/ds term.
function _offset_bspline_curvature(s::Paths.GeneralOffset, t)
    l = Paths.t_to_arclength(s.seg, t)
    r = 1 / _bspline_signed_curvature(s.seg.r, t)
    offset = Paths.getoffset(s, l)
    doffset = Paths.offset_derivative(s, l)
    d2offset = Paths.ForwardDiff.derivative(l_ -> Paths.offset_derivative(s, l_), l)

    ds_dl = 1 / sqrt((1 - offset / r)^2 + doffset^2)
    d2s_dl2 = -ds_dl^3 * doffset * (d2offset - (1 - offset / r) / r)

    g = Paths.Interpolations.gradient(s.seg.r, t)[1]
    base_tangent = g / norm(g)
    base_normal = Point(-base_tangent.y, base_tangent.x)
    # Same expression as Paths.tangent(s, l), using κ=1/r without arclength inversion.
    off_tangent = base_tangent + doffset * base_normal - offset * (1 / r) * base_tangent
    d2_seg =
        (
            (1 / r) * base_normal + d2offset * base_normal -
            2 * (1 / r) * base_tangent * doffset -
            ((1 / r) * base_normal) * ((1 / r) * offset)
        ) * ds_dl^2 + off_tangent * d2s_dl2
    return norm(d2_seg)
end

# Discretize using marching algorithm based on Hessian or curvature.
#
# Known limitation: the curvature guard below is t_scale-dependent, so it over-refines
# short, tight arcs (a 30°/2μm fillet gets ~101 points vs ~10 from circular_arc).
# A correct fix must be t_scale-independent while still sampling the middle of
# variable-curvature curves whose endpoints have cc≈0. That touches the broader
# path-rendering pipeline, so it is deferred from the rounding unification.
function discretization_grid(
    ddf,
    tolerance,
    bnds::Tuple{Float64, Float64}=(0.0, 1.0);
    t_scale=1.0,
    rtol=nothing
)
    dt = 0.01 * bnds[2]
    ts = zeros(100)
    ts[1] = bnds[1]
    t = bnds[1]
    i = 1
    cc = norm(ddf(t))
    while t < bnds[2]
        i = i + 1
        i > length(ts) && resize!(ts, 2 * length(ts))
        t = ts[i - 1]
        # Effective tolerance: use rtol * radius_of_curvature when it exceeds atol.
        # cc has units (curvature, e.g., rad/μm) so compare with zero(cc), not `0`.
        eff_tol = (!isnothing(rtol) && !iszero(cc)) ? max(tolerance, rtol / cc) : tolerance
        # Set dt based on distance from chord assuming constant curvature.
        # See the known limitation above for the curvature guard below.
        if cc >= 100 * 8 * eff_tol / (bnds[2]^2 * t_scale^2) # Update dt if curvature is not near zero
            dt = uconvert(NoUnits, sqrt(8 * eff_tol / cc) / t_scale)
        end
        if t + dt >= bnds[2]
            dt = bnds[2] - t
        end
        # Check that curvature didn't increase too much (decrease is fine)
        # Rare but may happen near inflection points
        cc_next = norm(ddf(t + dt))
        eff_tol_next =
            (!isnothing(rtol) && !iszero(cc_next)) ? max(tolerance, rtol / cc_next) :
            tolerance
        if (t_scale * dt)^2 * (cc_next - cc) / 24 > eff_tol_next
            dt = uconvert(NoUnits, sqrt(8 * eff_tol_next / cc_next) / t_scale)
            cc_next = norm(ddf(t + dt))
        end
        cc = cc_next
        ts[i] = min(bnds[2], t + dt)
        t = ts[i]
    end
    # Make sure last two points aren't unnecessarily close together
    if i > 2 && ts[i - 1] > (ts[i] + ts[i - 2]) / 2
        ts[i - 1] = (ts[i] + ts[i - 2]) / 2
    end
    return ts[1:i]
end
