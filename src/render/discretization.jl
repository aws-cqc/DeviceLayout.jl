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
function _bspline_curvature(r, t)
    g = Paths.Interpolations.gradient(r, t)[1]
    h = Paths.Interpolations.hessian(r, t)[1]
    return abs(g.x * h.y - g.y * h.x) / (g.x^2 + g.y^2)^(3 // 2)
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
    tracker = CuspTracker()
    grid = discretization_grid(
        t -> _offset_bspline_curvature(s, t; clamp_radius_ratio=0.1, tracker=tracker),
        tolerance;
        t_scale=l * max_speed,
        rtol=rtol
    )
    # A sign change of 1 − offset·κ means the offset point's velocity reverses
    # along the base tangent: a cusp, regardless of where samples landed.
    if tracker.tangential_min < 0 < tracker.tangential_max
        _warn_cusp(s.offset, s.seg.r(tracker.t_nearest))
    end
    return grid
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
    clamp_radius_ratio = 0.1
    tracker = CuspTracker()
    grid = discretization_grid(
        t -> _offset_bspline_curvature(
            s,
            t;
            clamp_radius_ratio=clamp_radius_ratio,
            tracker=tracker
        ),
        tolerance;
        t_scale=l * max(speed0, speed1),
        rtol=rtol
    )
    # A tangential-speed reversal is only a cusp if the full speed
    # √((1 − offset·κ)² + offset′²) also vanishes there; at the reversal it is
    # |offset′|, so a fast-varying offset turns the would-be cusp into smooth
    # sideways motion and should not warn.
    if tracker.tangential_min < 0 < tracker.tangential_max &&
       abs(tracker.offset_deriv_nearest) < clamp_radius_ratio
        l_nearest = Paths.t_to_arclength(s.seg, tracker.t_nearest)
        _warn_cusp(Paths.getoffset(s, l_nearest), s.seg.r(tracker.t_nearest))
    end
    return grid
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

# Track the extremes of the tangential speed component 1 − offset·κ
# across all kernel evaluations and check for a sign change after marching:
# the offset point's velocity reverses along the base tangent.
mutable struct CuspTracker
    tangential_min::Float64
    tangential_max::Float64
    abs_tangential_nearest::Float64 # |tangential| at the evaluation nearest a reversal
    t_nearest::Float64
    offset_deriv_nearest::Float64 # d(offset)/d(arclength) there; 0 for constant offsets
end
CuspTracker() = CuspTracker(Inf, -Inf, Inf, NaN, 0.0)

function _track_cusp!(tracker::CuspTracker, tangential, t, offset_deriv=0.0)
    tracker.tangential_min = min(tracker.tangential_min, tangential)
    tracker.tangential_max = max(tracker.tangential_max, tangential)
    if abs(tangential) < tracker.abs_tangential_nearest
        tracker.abs_tangential_nearest = abs(tangential)
        tracker.t_nearest = t
        tracker.offset_deriv_nearest = offset_deriv
    end
    return nothing
end

# Offset-BSpline curvature in base spline `t` space, avoiding an arclength-to-`t`
# root-find at every discretization step.
function _offset_bspline_curvature(
    s::Paths.ConstantOffset,
    t;
    clamp_radius_ratio=0.0,
    tracker=nothing
)
    # Near offset-curve cusps (|1 − offset·κ_base| → 0) the true offset curvature
    # diverges; clamp the denominator so the kernel doesn't chase sub-tolerance
    # bowtie loops. Identical to the true κ_off wherever |1 − offset·κ_base| > ε.
    # ε bounds the chord deviation as a multiple of derivative of base radius w.r.t. arclength
    # at ~ε·|dR/ds|·tol (dimensionless |dR/ds| ≈ O(1) for smooth splines).
    κ = _bspline_signed_curvature(s.seg.r, t)
    tangential = 1 - s.offset * κ
    isnothing(tracker) || _track_cusp!(tracker, tangential, t)
    return abs(κ) / max(abs(tangential), clamp_radius_ratio)
end

# Mirrors curvatureradius(::GeneralOffset, s), including its ignored offset*dκ/ds term.
function _offset_bspline_curvature(
    s::Paths.GeneralOffset,
    t;
    clamp_radius_ratio=0.0,
    tracker=nothing
)
    l = Paths.t_to_arclength(s.seg, t)
    r = 1 / _bspline_signed_curvature(s.seg.r, t)
    offset = Paths.getoffset(s, l)
    doffset = Paths.offset_derivative(s, l)
    d2offset = Paths.ForwardDiff.derivative(l_ -> Paths.offset_derivative(s, l_), l)

    # Same denominator clamp as for ConstantOffset
    denom = sqrt((1 - offset / r)^2 + doffset^2)
    isnothing(tracker) || _track_cusp!(tracker, 1 - offset / r, t, doffset)
    ds_dl = 1 / max(denom, clamp_radius_ratio)
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

function _warn_cusp(offset, base_pt)
    @warn """
       Offset curve has a cusp where the offset $(offset) approaches the curvature radius
       of the base curve, near the base curve point $(base_pt).
       Check that your geometry is correct—cusps and related self-intersections are usually unwanted.
       Some operations may not handle cusps or self-intersecting curves as expected.
       """
end

# Discretize using marching algorithm based on Hessian or curvature.
#
# Known limitation: the curvature guard below is t_scale-dependent, so it over-refines
# short, tight arcs (a 30°/2μm fillet gets ~101 points vs ~10 from circular_arc).
# A correct fix must be t_scale-independent while still sampling the middle of
# variable-curvature curves whose endpoints have cc≈0.
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
