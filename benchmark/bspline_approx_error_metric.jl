# Prototype benchmark: dense (polyline) vs Gauss-point error metric in
# `bspline_approximation` (memory issue sketch `bspline-approx-next-level`, direction #3).
#
# Run from the repo root:
#   julia --project=. benchmark/bspline_approx_error_metric.jl
#
# For each case, runs `bspline_approximation` with both error metrics and reports:
#   - wall time (minimum of several runs, after warmup)
#   - number of output subsegments
#   - true max error of the accepted output, measured against a dense reference
#     discretization of the exact (offset) curve, independent of either metric.
#     The referee polyline is fine enough that its own chord error is ≲0.2nm.

using DeviceLayout
using DeviceLayout: Paths, Point
using DeviceLayout.Paths: BSpline, bspline_approximation, pathlength
using DeviceLayout.PreferMicrons: μm, nm
using LinearAlgebra: norm
using Printf
import Unitful

# ---------- referee: true max error against dense exact reference ----------

function _pt_seg_dist(p, a, b)
    ab = b - a
    ap = p - a
    denom = ab.x^2 + ab.y^2
    t =
        iszero(denom) ? 0.0 :
        clamp(
            Unitful.ustrip(Unitful.NoUnits, (ap.x * ab.x + ap.y * ab.y) / denom),
            0.0,
            1.0
        )
    return norm(p - (a + t * ab))
end

function true_max_error(f, approx; nref=1500, nfine=1001)
    L = pathlength(f)
    ss = range(zero(L), L, length=nref)
    pex = f.(ss) # exact target points (OffsetSegment call applies the offset)
    pts = eltype(pex)[]
    for seg in approx.segments
        append!(pts, seg.r.(range(0.0, 1.0, length=nfine)))
    end
    maxd = zero(L)
    for p in pex
        best = Inf * oneunit(L)
        for i = 1:(length(pts) - 1)
            best = min(best, _pt_seg_dist(p, pts[i], pts[i + 1]))
        end
        maxd = max(maxd, best)
    end
    return maxd
end

# ---------- cases ----------

# Gentle 2-point spline (typical CPW route segment)
b_gentle = BSpline(
    [Point(0.0μm, 0.0μm), Point(1000.0μm, 200.0μm)],
    Point(800.0μm, 0.0μm),
    Point(800.0μm, 0.0μm)
)

# S-curve with waypoints and moderate curvature
b_scurve = BSpline(
    [
        Point(0.0μm, 0.0μm),
        Point(300.0μm, 150.0μm),
        Point(600.0μm, -150.0μm),
        Point(900.0μm, 0.0μm)
    ],
    Point(400.0μm, 0.0μm),
    Point(400.0μm, 0.0μm)
)

# Extreme signed curvature of the S-curve, for the near-cusp case
κs = [Paths.signed_curvature(b_scurve, s) for s in range(0.0μm, pathlength(b_scurve), 401)]
κ_ext = κs[argmax(abs.(κs))]
r_min = 1 / abs(κ_ext)
@printf("S-curve min radius of curvature: %.2f μm\n\n", Unitful.ustrip(μm, r_min))

taper(L) = s -> 5.0μm + 10.0μm * s / L

cases = [
    ("gentle, off +5μm", Paths.offset(b_gentle, 5.0μm)),
    ("gentle, off -12μm", Paths.offset(b_gentle, -12.0μm)),
    ("S-curve, off +10μm", Paths.offset(b_scurve, 10.0μm)),
    ("S-curve, off -10μm", Paths.offset(b_scurve, -10.0μm)),
    ("S-curve taper 5→15μm", Paths.offset(b_scurve, taper(pathlength(b_scurve)))),
    ("S-curve near-cusp 0.9r_min", Paths.offset(b_scurve, 0.9 / κ_ext)),
    # At/beyond the min radius of curvature the offset curve has a cusp / a
    # self-intersecting loop. These probe the dense metric's silent-skip
    # behavior (samples whose normal ray misses the candidate polyline are
    # dropped from the error estimate) vs the Gauss metric's forced refinement.
    ("S-curve AT cusp 1.0r_min", Paths.offset(b_scurve, 1.0 / κ_ext)),
    ("S-curve loop 1.2r_min", Paths.offset(b_scurve, 1.2 / κ_ext)),
    # Plain (non-offset) generic Segment dispatch
    ("Turn 90°, r=100μm", Paths.Turn(π / 2, 100.0μm; p0=Point(0.0μm, 0.0μm), α0=0.0))
]

# ---------- run ----------

function bench(f; errmetric)
    approx = bspline_approximation(f; errmetric) # warmup + reparam cache build
    t = minimum((@elapsed bspline_approximation(f; errmetric)) for _ = 1:7)
    return approx, t
end

const METRICS = (:dense, :gauss, :gaussfit)

@printf("%-26s", "case")
for m in METRICS
    @printf(" %10s %5s %10s", "t_$m", "N", "err (nm)")
end
println()
for (name, f) in cases
    @printf("%-26s", name)
    for m in METRICS
        a, t = bench(f; errmetric=m)
        e = true_max_error(f, a)
        @printf(" %8.2fms %5d %10.3f", 1e3 * t, length(a.segments), Unitful.ustrip(nm, e))
    end
    println()
end
