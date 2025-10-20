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
