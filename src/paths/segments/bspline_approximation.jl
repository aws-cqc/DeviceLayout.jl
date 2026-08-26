import QuadGK

# Sample points used to estimate approximation error
function _testvals(f::Paths.Segment{T}, f_approx::Paths.BSpline) where {T}
    l = Paths.pathlength(f)
    tgrid = DeviceLayout.discretization_grid(f, _default_curve_atol(T))
    sgrid = tgrid * l
    offsets = fill(zero(T), length(tgrid))
    exact = f.(sgrid)
    dir = direction.(Ref(f), sgrid)
    normal = oneunit(T) * Point.(-sin.(dir), cos.(dir))
    return tgrid, exact, normal, offsets
end

# For offset segments, sample non-offset curve, plus normals and offset values
function _testvals(f::Paths.OffsetSegment{T}, f_approx::Paths.BSpline) where {T}
    l = Paths.pathlength(f)
    tgrid = DeviceLayout.discretization_grid(f, _default_curve_atol(T))
    sgrid = tgrid * l
    # Don't actually calculate the exact curve, we'll only check that the offset is correct
    offsets = abs.(getoffset.(Ref(f), sgrid))
    exact = f.seg.(sgrid)
    dir = direction.(Ref(f.seg), sgrid)
    normal = oneunit(T) * Point.(-sin.(dir), cos.(dir))
    return tgrid, exact, normal, offsets
end

# Offset bsplines use tgrid directly to calculate a bit faster
function _testvals(f::Paths.GeneralOffset{T, BSpline{T}}, f_approx::Paths.BSpline) where {T}
    tgrid = DeviceLayout.discretization_grid(f.seg, _default_curve_atol(T))
    sgrid = t_to_arclength.(Ref(f.seg), tgrid)
    offsets = abs.(getoffset.(Ref(f), sgrid))
    # Don't actually calculate the exact curve, we'll only check that the offsets are correct
    exact = f.seg.r.(tgrid)
    tangent = first.(Paths.Interpolations.gradient.(Ref(f.seg.r), tgrid))
    normal = Point.(-gety.(tangent), getx.(tangent))
    return tgrid, exact, normal, offsets
end

# don't even need to calculate sgrid for constant offset BSpline
function _testvals(
    f::Paths.ConstantOffset{T, BSpline{T}},
    f_approx::Paths.BSpline
) where {T}
    tgrid = DeviceLayout.discretization_grid(f.seg, _default_curve_atol(T))
    off = abs(getoffset(f))
    # Don't actually calculate the exact curve, we'll only check that the offset is correct
    exact = f.seg.r.(tgrid)
    tangent = first.(Paths.Interpolations.gradient.(Ref(f.seg.r), tgrid))
    normal = Point.(-gety.(tangent), getx.(tangent))
    return tgrid, exact, normal, fill(off, length(tgrid))
end

_t_halflength(::Segment) = 0.5
_t_halflength(seg::OffsetSegment) = _t_halflength(seg.seg)
_t_halflength(seg::BSpline) = arclength_to_t(seg, pathlength(seg) / 2)

function _split_testvals(testvals, seg::Segment{T}) where {T}
    tgrid, exact, normal, offset = testvals
    t_half = _t_halflength(seg)
    idx_h2 = findfirst(t -> t > t_half, tgrid)
    isnothing(idx_h2) && # segment is so short there are no points in test discretization
        @error """
        B-spline approximation of $seg failed to converge.
        Check curve for cusps and self-intersections, which may cause approximation to fail.
        Otherwise, increase `atol` to relax tolerance.
        """
    t_h1 = tgrid[1:(idx_h2 - 1)]
    t_h2 = tgrid[idx_h2:end]
    new_tgrid_h1 = t_h1 / t_half
    new_tgrid_h2 = (t_h2 .- t_half) / (1 - t_half)
    return (
        new_tgrid_h1,
        (@view exact[1:(idx_h2 - 1)]),
        (@view normal[1:(idx_h2 - 1)]),
        (@view offset[1:(idx_h2 - 1)])
    ),
    (
        new_tgrid_h2,
        (@view exact[idx_h2:end]),
        (@view normal[idx_h2:end]),
        (@view offset[idx_h2:end])
    )
end

# For offsets, we use the underlying curve and check that the approximation is offset away
function _approximation_error(
    f::Paths.Segment{T},
    f_approx::Paths.BSpline{T},
    testvals=_testvals(f, f_approx)
) where {T}
    tgrid, exact, exact_normal, offsets = testvals
    approx = f_approx.r.(tgrid)
    # f_approx may not be arclength-parameterized
    # but each exact point should be within 1nm of some line segment on
    # the discretization of f_approx
    idx_0 = 1
    maxerr = zero(T)
    for (p, normal, off) in zip(exact, exact_normal, offsets) # For each exact point, project it onto the approximate segments        
        # Find the first approx segment where the projection lies on that segment
        # (Starting with the approximate segment previously found)
        for idx = idx_0:(length(approx) - 1)
            intersects, ixn = Polygons.intersection(
                Polygons.Ray(p, p + normal),
                Polygons.LineSegment(approx[idx], approx[idx + 1])
            )
            if !intersects # Maybe we checked the ray in the wrong direction
                intersects, ixn = Polygons.intersection(
                    Polygons.Ray(p, p - normal),
                    Polygons.LineSegment(approx[idx], approx[idx + 1])
                )
            end
            if intersects # We found a projection that lies on the approximation
                idx_0 = idx
                maxerr = max(maxerr, abs(norm(p - ixn) - off))
                break
            end
        end
    end
    return maxerr
end

function _initial_guess(f::Paths.Segment{T}; len=nothing) where {T}
    l = arclength(f) # *Not* pathlength!
    t0 = Point(cos(α0(f)), sin(α0(f))) * l
    t1 = Point(cos(α1(f)), sin(α1(f))) * l
    return BSpline{T}([p0(f), p1(f)], t0, t1)
end

function _initial_guess(f::Paths.OffsetSegment{T, BSpline{T}}; len=pathlength(f)) where {T}
    # Can do a little better with BSpline offsets by taking into account non-arclength parameterization
    t0 = tangent(f, zero(T)) * dsdt(0.0, f.seg.r)
    t1 = tangent(f, len) * dsdt(1.0, f.seg.r)
    return BSpline{T}([p0(f), p1(f)], t0, t1) # Don't even worry about original knots
end

_default_curve_atol(::Type{<:Real}) = 1e-3
_default_curve_atol(::Type{<:Length}) = 1nm

############################################################################
# Prototype (#3): Gauss-point error metric.
#
# The dense metric above builds a full discretization grid of the curve at the
# package-default atol (1nm) and measures each exact sample against the
# *polyline* discretization of the candidate. That has two structural problems:
#   1. Cost scales with the 1nm grid regardless of the requested atol; post-#245
#      this dense sampling dominates bspline_approximation.
#   2. The polyline's own chord-height error is ~atol by construction, so the
#      accept/reject decision carries a measurement noise floor of order atol.
# Instead, sample a fixed, small set of Gauss-Legendre nodes per candidate and
# intersect each exact-curve normal ray with the candidate *cubic itself* via a
# scalar root solve. The fit error of a cubic Hermite candidate is a smooth,
# low-frequency function of the parameter, so a modest fixed sample captures
# its maximum well. (Same approach as kurbo / Levien's cubic fitting.)
############################################################################

# Gauss-Legendre nodes mapped from [-1, 1] to (0, 1). Endpoints are excluded
# because the candidate interpolates them exactly.
const _GAUSS_NODES = (QuadGK.gauss(24)[1] .+ 1) ./ 2

_cross2(a::Point, b::Point) = getx(a) * gety(b) - gety(a) * getx(b)

# Per-candidate exact samples at the Gauss nodes: (tgrid, exact, normal, offsets)
# with the same semantics as _testvals. `normal` need not be normalized: it is
# only used as a ray direction (the error is measured as a point distance).
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
        # normal line: force refinement. (The dense metric silently skips such
        # samples instead.)
        isnothing(u) && return Inf * oneunit(T)
        maxerr = max(maxerr, abs(norm(f_approx.r(u) - p) - off))
    end
    return maxerr
end

function _bspline_approximation_gauss(
    f::Paths.Segment{T};
    atol=_default_curve_atol(T),
    maxits=10
) where {T}
    approxs = BSpline{T}[]
    err = _approx_gauss!(approxs, f, atol, 0, maxits)
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
function _approx_gauss!(approxs, f::Paths.Segment{T}, atol, depth, maxdepth) where {T}
    approx = _initial_guess(f)
    err = _approximation_error_gauss(approx, _gauss_testvals(f))
    if err > atol && depth < maxdepth
        suberr = zero(T)
        for sub in split(f, pathlength(f) / 2)
            suberr = max(suberr, _approx_gauss!(approxs, sub, atol, depth + 1, maxdepth))
        end
        return suberr
    end
    push!(approxs, approx)
    return err > atol ? err : zero(T)
end

# Approximate f with a BSpline
function bspline_approximation(
    f::Paths.Segment{T};
    atol=_default_curve_atol(T),
    maxits=10,
    rtol=nothing,
    errmetric=:dense
) where {T}
    # errmetric=:gauss is a prototype alternative error measurement; see above.
    errmetric === :gauss && return _bspline_approximation_gauss(f; atol, maxits)
    # rtol is accepted for API consistency with render-time callers (e.g. OffsetSegment).
    # The internal _testvals sampling grid is construction-time, not render-time, and
    # intentionally stays at the package default atol.
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
