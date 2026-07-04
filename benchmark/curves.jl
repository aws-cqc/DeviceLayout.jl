SUITE["curves"] = BenchmarkGroup()

# Build and render turns
function turns()
    c = Cell{Float64}("test")
    turn_path = Path{Float64}()
    for i = 1:10
        turn!(turn_path, 45°, 20.0 * i, Paths.CPW(10.0, 6.0))
        turn!(turn_path, -45°, 20.0 * i)
    end
    return render!(c, turn_path, GDSMeta())
end

# Build and render B-splines
function bsplines()
    c = Cell{Float64}("test")
    bspline_path = Path{Float64}()
    for i = 1:10
        bspline!(
            bspline_path,
            [p0(bspline_path) + Point(20 * i, 10 * i)],
            0°,
            Paths.CPW(10.0, 6.0),
            endpoints_speed=20.0 * i
        )
    end
    return render!(c, bspline_path, GDSMeta())
end

# Approximate offset curves with B-splines
function offset_bspline_approx()
    bspline_path = Path{Float64}()
    for i = 1:10
        bspline!(
            bspline_path,
            [p0(bspline_path) + Point(20 * i, 10 * i^2)],
            0°,
            Paths.CPW(10.0, 6.0),
            endpoints_speed=20.0 * i
        )
        Paths.bspline_approximation(Paths.offset(bspline_path[end].seg, 11.0))
    end
end

SUITE["curves"]["turns_render"] = @benchmarkable turns()
SUITE["curves"]["bsplines_render"] = @benchmarkable bsplines()
SUITE["curves"]["offset_bspline_approximation"] = @benchmarkable offset_bspline_approx()

# A representative BSpline for per-primitive arclength microbenchmarks.
function _bench_bspline()
    p = Path{Float64}()
    bspline!(p, [Point(40.0, 20.0), Point(80.0, 0.0)], 0°, Paths.Trace(1.0); endpoints_speed=60.0)
    return p[end].seg
end

# `setup` builds a fresh spline and warms its arclength cache, so each sample measures
# steady-state lookup cost rather than the one-time build.
SUITE["curves"]["bspline_pathlength"] =
    @benchmarkable Paths.pathlength(b) setup = (b = _bench_bspline(); Paths.pathlength(b))
SUITE["curves"]["bspline_t_to_arclength"] =
    @benchmarkable Paths.t_to_arclength(b, 0.5) setup =
        (b = _bench_bspline(); Paths.pathlength(b))
SUITE["curves"]["bspline_arclength_to_t"] =
    @benchmarkable Paths.arclength_to_t(b, s) setup =
        (b = _bench_bspline(); s = Paths.pathlength(b) / 2)
SUITE["curves"]["bspline_eval"] =
    @benchmarkable b(s) setup = (b = _bench_bspline(); s = Paths.pathlength(b) / 2)
# One-time cache build cost (fresh spline each sample, no warm-up).
SUITE["curves"]["bspline_build_reparam"] =
    @benchmarkable Paths._build_reparam(b) setup = (b = _bench_bspline())
