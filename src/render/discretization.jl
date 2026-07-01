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
# TODO: For varying base curvature, a single t_scale is an approximation. A fully
# correct approach would incorporate local curve speed into the marching kernel.
function discretization_grid(s::Paths.ConstantOffset, tolerance; rtol=nothing)
    l = pathlength(s)
    # Use the maximum curve speed at the endpoints as t_scale. This is conservative:
    # it may produce slightly more points than necessary, but never exceeds tolerance.
    # (Exact for constant-curvature base curves like Turn.)
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
