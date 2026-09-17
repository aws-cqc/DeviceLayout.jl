import QuadGK

function _initial_guess(f::Paths.Segment{T}) where {T}
    l = arclength(f) # *Not* pathlength!
    t0 = Point(cos(α0(f)), sin(α0(f))) * l
    t1 = Point(cos(α1(f)), sin(α1(f))) * l
    return BSpline{T}([p0(f), p1(f)], t0, t1)
end

function _initial_guess(f::Paths.OffsetSegment{T, BSpline{T}}) where {T}
    # Can do a little better with BSpline offsets by taking into account non-arclength parameterization
    t0 = tangent(f, zero(T)) * dsdt(0.0, f.seg.r)
    t1 = tangent(f, pathlength(f)) * dsdt(1.0, f.seg.r)
    return BSpline{T}([p0(f), p1(f)], t0, t1) # Don't even worry about original knots
end

_default_curve_atol(::Type{<:Real}) = 1e-3
_default_curve_atol(::Type{<:Length}) = 1nm

############################################################################
# Gauss-point error metric.
#
# Measuring a candidate against a dense polyline discretization of the exact
# curve at the package-default atol has two structural problems: cost scales
# with that grid regardless of the requested atol, and the polyline's own
# chord-height error is ~atol by construction, so the accept/reject decision
# carries a measurement noise floor of order atol. Instead, sample a fixed,
# small set of Gauss-Legendre nodes per candidate and intersect each
# exact-curve normal ray with the candidate *cubic itself* via a scalar root
# solve. The fit error of a cubic Hermite candidate is a smooth, low-frequency
# function of the parameter, so a modest fixed sample captures its maximum
# well. (Same approach as kurbo / Levien's cubic fitting.)
############################################################################

# Gauss-Legendre nodes mapped from [-1, 1] to (0, 1). Endpoints are excluded
# because the candidate interpolates them exactly.
const _GAUSS_NODES = (QuadGK.gauss(24)[1] .+ 1) ./ 2

_cross2(a::Point, b::Point) = getx(a) * gety(b) - gety(a) * getx(b)

# Per-candidate exact samples at the Gauss nodes: (tgrid, exact, normal, offsets).
# `normal` need not be normalized: it is only used as a ray direction (the
# error is measured as a point distance).
function _gauss_testvals(f::Paths.Segment{T}) where {T}
    l = Paths.pathlength(f)
    sgrid = _GAUSS_NODES * l
    exact = f.(sgrid)
    dir = direction.(Ref(f), sgrid)
    normal = oneunit(T) * Point.(-sin.(dir), cos.(dir))
    return _GAUSS_NODES, exact, normal, fill(zero(T), length(sgrid))
end

# For offset segments, sample the base curve and check the offset distance
function _gauss_testvals(f::Paths.OffsetSegment{T}) where {T}
    l = Paths.pathlength(f)
    sgrid = _GAUSS_NODES * l
    offsets = abs.(getoffset.(Ref(f), sgrid))
    exact = f.seg.(sgrid)
    dir = direction.(Ref(f.seg), sgrid)
    normal = oneunit(T) * Point.(-sin.(dir), cos.(dir))
    return _GAUSS_NODES, exact, normal, offsets
end

# Offset BSplines evaluate the interpolation directly (no arclength_to_t)
function _gauss_testvals(f::Paths.GeneralOffset{T, BSpline{T}}) where {T}
    tgrid = _GAUSS_NODES
    sgrid = t_to_arclength.(Ref(f.seg), tgrid)
    offsets = abs.(getoffset.(Ref(f), sgrid))
    exact = f.seg.r.(tgrid)
    tangent = first.(Paths.Interpolations.gradient.(Ref(f.seg.r), tgrid))
    normal = Point.(-gety.(tangent), getx.(tangent))
    return tgrid, exact, normal, offsets
end

function _gauss_testvals(f::Paths.ConstantOffset{T, BSpline{T}}) where {T}
    tgrid = _GAUSS_NODES
    off = abs(getoffset(f))
    exact = f.seg.r.(tgrid)
    tangent = first.(Paths.Interpolations.gradient.(Ref(f.seg.r), tgrid))
    normal = Point.(-gety.(tangent), getx.(tangent))
    return tgrid, exact, normal, fill(off, length(tgrid))
end

# Find u ∈ [0, 1] such that r(u) lies on the line through p along n, i.e.
# g(u) = (r(u) - p) × n = 0. Newton seeded at the sample's own parameter
# (candidates roughly preserve parameterization), bisection scan as fallback.
# Returns nothing if the line misses the candidate entirely.
function _ray_spline_param(p::Point, n::Point, r, t_seed)
    u = t_seed
    for _ = 1:20
        g = _cross2(r(u) - p, n)
        dg = _cross2(first(Paths.Interpolations.gradient(r, u)), n)
        iszero(dg) && break # normal parallel to candidate tangent; use fallback
        du = g / dg
        u_new = u - du
        # The interpolation is only defined on [0, 1]; if Newton steps outside
        # (root beyond the candidate's domain, or diverging), use the fallback.
        (u_new < 0.0 || u_new > 1.0) && break
        u = u_new
        abs(du) < 1e-12 && return u
    end
    return _ray_param_bisect(p, n, r, t_seed)
end

function _ray_param_bisect(p::Point, n::Point, r, t_seed)
    N = 32
    us = range(0.0, 1.0, length=N + 1)
    gs = [_cross2(r(u) - p, n) for u in us]
    best = nothing
    for i = 1:N
        glo, ghi = gs[i], gs[i + 1]
        (sign(glo) == sign(ghi) && !iszero(glo)) && continue
        lo, hi = us[i], us[i + 1]
        for _ = 1:50
            mid = (lo + hi) / 2
            gm = _cross2(r(mid) - p, n)
            if sign(gm) == sign(glo)
                lo, glo = mid, gm
            else
                hi = mid
            end
        end
        u = (lo + hi) / 2
        # The line can cross a cubic up to 3 times; keep the root nearest the seed
        if isnothing(best) || abs(u - t_seed) < abs(best - t_seed)
            best = u
        end
    end
    return best
end

function _approximation_error_gauss(f_approx::Paths.BSpline{T}, testvals) where {T}
    tgrid, exact, normal, offsets = testvals
    maxerr = zero(T)
    for (t, p, n, off) in zip(tgrid, exact, normal, offsets)
        u = _ray_spline_param(p, n, f_approx.r, t)
        # A missed ray means the candidate doesn't even cross this sample's
        # normal line: force refinement.
        isnothing(u) && return Inf * oneunit(T)
        maxerr = max(maxerr, abs(norm(f_approx.r(u) - p) - off))
    end
    return maxerr
end

############################################################################
# Tangent-magnitude fitting.
#
# A 2-point BSpline candidate with Neumann end conditions is exactly the cubic
# Hermite interpolant r(u) = h00(u)p₀ + h10(u)T₀ + h01(u)p₁ + h11(u)T₁ (four
# conditions — two positions, two end derivatives — determine the cubic). With
# endpoint positions and tangent DIRECTIONS fixed by G1 continuity, candidates
# form a two-parameter family: T₀ = s₀t₀, T₁ = s₁t₁. The normal-direction
# mismatch at each sample is LINEAR in (s₀, s₁), so the least-squares fit is a
# closed-form 2×2 solve — no iterative optimizer. (Levien's cubic fitting pins
# the same two-parameter family with area/moment constraints instead; fitted
# cubics converge like O(h⁶) vs O(h⁴) for the fixed-magnitude initial guess.)
############################################################################

_hermite00(u) = (1 + 2u) * (1 - u)^2
_hermite10(u) = u * (1 - u)^2
_hermite01(u) = u^2 * (3 - 2u)
_hermite11(u) = u^2 * (u - 1)

# Least-squares fit of the tangent magnitude scales (s₀, s₁) of `approx` to the
# exact samples in `testvals`, using `approx` itself for ray correspondence and
# for the side of the base curve each (unsigned) offset sample lies on.
# Returns the fitted candidate, or nothing when the fit has no leverage (e.g.
# nearly straight: the tangents barely move points in the normal direction).
function _fit_tangent_magnitudes(approx::Paths.BSpline{T}, testvals) where {T}
    tgrid, exact, normal, offsets = testvals
    pa, pb = approx.p[1], approx.p[end]
    t0, t1 = approx.t0, approx.t1
    uT = oneunit(T)
    A11 = A12 = A22 = b1 = b2 = 0.0
    nvalid = 0
    for (t, p, n, off) in zip(tgrid, exact, normal, offsets)
        u = _ray_spline_param(p, n, approx.r, t)
        isnothing(u) && continue
        n̂ = n / norm(n)
        # Exact target point: offsets are stored unsigned, so take the side of
        # the base curve the current candidate is on at this sample
        d = dot(approx.r(u) - p, n̂)
        q = p + (d < zero(d) ? -off : off) * n̂
        a1 = _hermite10(u) * dot(t0, n̂) / uT
        a2 = _hermite11(u) * dot(t1, n̂) / uT
        rhs = (dot(q, n̂) - _hermite00(u) * dot(pa, n̂) - _hermite01(u) * dot(pb, n̂)) / uT
        A11 += a1 * a1
        A12 += a1 * a2
        A22 += a2 * a2
        b1 += a1 * rhs
        b2 += a2 * rhs
        nvalid += 1
    end
    nvalid < 6 && return nothing
    det = A11 * A22 - A12 * A12
    det <= 1e-10 * (A11 * A22 + eps()) && return nothing
    s0 = (b1 * A22 - b2 * A12) / det
    s1 = (b2 * A11 - b1 * A12) / det
    # Preserve tangent directions (G1): reject sign flips and runaway scales
    (0.05 <= s0 <= 20.0 && 0.05 <= s1 <= 20.0) || return nothing
    return BSpline{T}([pa, pb], s0 * t0, s1 * t1)
end

# Fitted candidates are accepted only against atol scaled by this margin: a
# near-optimal fit's error curve equioscillates (more, narrower lobes than the
# single-lobed initial-guess error), so the fixed Gauss sample can undershoot
# the true peak slightly. O(h⁶) convergence makes the margin cheap: ~2% extra
# subdivision at 0.9. The unfitted acceptance test stays at plain atol.
const _FIT_ACCEPT_MARGIN = 0.9

# Fit, verify with the true Gauss metric, and iterate the correspondence once
# if the first fit is not yet within tolerance. Returns the best (candidate,
# error) seen, never worse than the input pair.
function _fit_and_check(approx::Paths.BSpline{T}, testvals, atol, err) where {T}
    best, besterr = approx, err
    cand = approx
    for _ = 1:2
        fitted = _fit_tangent_magnitudes(cand, testvals)
        isnothing(fitted) && break
        errf = _approximation_error_gauss(fitted, testvals)
        if errf < besterr
            best, besterr = fitted, errf
        end
        besterr <= _FIT_ACCEPT_MARGIN * atol && break
        cand = fitted
    end
    return best, besterr
end

# Approximate f with a BSpline: recursive midpoint subdivision, accepting each
# leaf once its Gauss-point error (after tangent-magnitude fitting) is within atol.
function bspline_approximation(
    f::Paths.Segment{T};
    atol=_default_curve_atol(T),
    maxits=10,
    rtol=nothing
) where {T}
    # rtol is accepted for API consistency with render-time callers (e.g. OffsetSegment).
    approxs = BSpline{T}[]
    err = _approx!(approxs, f, atol, 0, maxits)
    if err > atol
        @warn """
        Maximum error $err > tolerance $atol after $maxits refinement iterations.
        Check curve $f for cusps and self-intersections, which may cause approximation to fail.
        Increase `maxits` or manually split path to refine further, or increase `atol` to relax tolerance.
        """
    end
    return CompoundSegment(convert(Vector{Segment{T}}, approxs))
end

# Push accepted candidates onto `approxs`; return the largest estimated error
# among leaves accepted only because `maxdepth` was reached (zero if all leaves
# converged), so the caller can warn once per curve rather than once per leaf.
function _approx!(approxs, f::Paths.Segment{T}, atol, depth, maxdepth) where {T}
    approx = _initial_guess(f)
    testvals = _gauss_testvals(f)
    err = _approximation_error_gauss(approx, testvals)
    tol = atol
    if err > atol
        fitted, errf = _fit_and_check(approx, testvals, atol, err)
        if errf < err
            approx, err = fitted, errf
            # Fitted candidates must clear the tighter acceptance threshold
            tol = _FIT_ACCEPT_MARGIN * atol
        end
    end
    if err > tol && depth < maxdepth
        suberr = zero(T)
        for sub in split(f, pathlength(f) / 2)
            suberr = max(suberr, _approx!(approxs, sub, atol, depth + 1, maxdepth))
        end
        return suberr
    end
    push!(approxs, approx)
    return err > tol ? err : zero(T)
end

# Approximate f with a BSpline.
#
# `errmetric` selects how candidate error is estimated:
#   :gaussfit (default) — Gauss-point metric plus closed-form fitting of the
#       candidate tangent magnitudes before subdividing (see above).
#   :gauss — Gauss-point metric with fixed-magnitude candidates only.
#   :dense — legacy metric: project a dense (package-default atol) sampling of
#       the exact curve onto the candidate's polyline discretization. Retained
#       for comparison during the transition; note its accept/reject decision
#       carries a noise floor of order atol (the polyline's own chord error),
#       and samples whose normal ray misses the candidate polyline are silently
#       dropped from the estimate, which can accept out-of-tolerance results
#       near cusps without warning.
function bspline_approximation(
    f::Paths.Segment{T};
    atol=_default_curve_atol(T),
    maxits=10,
    rtol=nothing,
    errmetric=:gaussfit
) where {T}
    errmetric === :gauss && return _bspline_approximation_gauss(f; atol, maxits)
    errmetric === :gaussfit &&
        return _bspline_approximation_gauss(f; atol, maxits, fit=true)
    # rtol is accepted for API consistency with render-time callers (e.g. OffsetSegment).
    # The internal _testvals sampling grid is construction-time, not render-time, and
    # intentionally stays at the package default atol.
    #
    # Canonicalize traversal direction before approximating. The refinement loop
    # is not reversal-symmetric, so this ensures a segment and its reverse are
    # approximated by the same splines between the same split points, before being
    # reversed back to the original traversal direction if necessary. This is
    # particularly important in the common case where the segment and its reverse
    # describe a shared boundary between two faces.
    #
    # Compare endpoints with a tolerance band rather than exact `>`: `reverse` need
    # not swap the endpoints bitwise, so an exact comparison can pick the "larger"
    # endpoint for both a segment and its reverse (when their coordinates differ
    # only at the ulp level), which would reverse both and defeat the point. Order
    # by x, then y, treating differences within `tol` as equal (so nearly-coincident
    # endpoints never flip on floating-point noise).
    tol = 2 * DeviceLayout.onenanometer(T)
    p_start, p_stop = p0(f), p1(f)
    dx, dy = getx(p_start) - getx(p_stop), gety(p_start) - gety(p_stop)
    is_descending = abs(dx) > tol ? dx > zero(dx) : (abs(dy) > tol ? dy > zero(dy) : false)
    if is_descending
        return reverse(
            bspline_approximation(reverse(f); atol=atol, maxits=maxits, rtol=rtol)
        )
    end
    # Sample points from f and use them to create the BSpline interpolation
    approx = _initial_guess(f)
    # Sample a dense set of points to test approximation against
    # (These testvals can be reused, although currently it's only reused for offsets of BSplines)
    testvals = _testvals(f, approx)
    # Calculate the maximum distance between approx and its projection onto the
    # discretization of the exact curve given by testvals
    err = _approximation_error(f, approx, testvals)
    # Double the number of interpolation points until the error is below tolerance
    refine = 1
    segs = Segment{T}[f]
    approxs = BSpline{T}[approx]
    seg_errs = T[err]
    split_tv = [testvals]
    while err > atol
        if refine > maxits
            @warn """
            Maximum error $err > tolerance $atol after $(refine-1) refinement iterations.
            Check curve $f for cusps and self-intersections, which may cause approximation to fail.
            Increase `maxits` or manually split path to refine further, or increase `atol` to relax tolerance.
            """
            break
        end
        err = 0.0 * oneunit(T)
        idx = 1
        while idx <= length(segs)
            if seg_errs[idx] > atol # Only split if tolerance is not yet met
                seg = segs[idx]
                approx = approxs[idx]
                tv = split_tv[idx]
                # Split segment and corresponding testvals in half by pathlength
                # (for offset paths this splits by underlying pathlength, not arclength of offset)
                halfseg_length = pathlength(seg) / 2
                subsegs = split(seg, halfseg_length)
                sub_tvs = _split_testvals(tv, seg)
                # Get approximation and estimate error for each subsegment
                approx_and_err = map(zip(subsegs, sub_tvs)) do (subseg, sub_tv)
                    approx = _initial_guess(subseg; len=halfseg_length)
                    seg_err = _approximation_error(subseg, approx, sub_tv)
                    return approx, seg_err
                end
                splice!(segs, idx, subsegs)
                splice!(approxs, idx, first.(approx_and_err))
                splice!(seg_errs, idx, last.(approx_and_err))
                splice!(split_tv, idx, sub_tvs)
                idx += 1 # Extra increment because we increased length(segs) by 1
            end
            idx += 1
        end
        err = maximum(seg_errs)
        refine = refine + 1
    end
    return CompoundSegment(convert(Vector{Segment{T}}, approxs))
end

bspline_approximation(b::Paths.BSpline; kwargs...) = copy(b)
