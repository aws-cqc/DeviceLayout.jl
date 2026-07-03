# Tests for relative-tolerance (`rtol`) kwarg threaded through
# `discretize_curve` / `discretization_grid` and the style-specific
# `to_polygons` methods in trace.jl / cpw.jl / curvilinear.jl.

@testitem "rtol_reduces_segment_count_on_large_radius" setup = [CommonTestSetup] begin
    # π/2 Turn with R=1mm, atol=1nm, rtol=1e-4.
    # Expected segment-count reduction ≈ sqrt(rtol · R / atol)
    # = sqrt(1e-4 · 1e6 / 1) = 10×
    pa = Path(μm, Point(0, -1)mm)
    turn!(pa, π / 2, 1000.0μm, Paths.Trace(10.0μm)) # R = 1mm

    # atol-alone baseline
    c_atol = Cell("atol_only", nm)
    render!(c_atol, pa, GDSMeta(0); atol=1nm)

    # atol + rtol
    c_rtol = Cell("atol_rtol", nm)
    render!(c_rtol, pa, GDSMeta(0); atol=1nm, rtol=1e-4)

    vcount_atol = sum(length(points(e)) for e in c_atol.elements)
    vcount_rtol = sum(length(points(e)) for e in c_rtol.elements)
    # chord midpoints on the outer arc.
    # div(vcount, 2) does not detect the arc boundary; it assumes the longer outer
    # arc is emitted first, so the leading half is all outer-arc points (radius r_outer).
    r_outer = 1.005mm
    half_atol = div(vcount_atol, 2)
    half_rtol = div(vcount_rtol, 2)
    midpoints_atol =
        (
            points(c_atol.elements[1])[1:(half_atol - 1)] .+
            points(c_atol.elements[1])[2:half_atol]
        ) / 2
    midpoints_rtol =
        (
            points(c_rtol.elements[1])[1:(half_rtol - 1)] .+
            points(c_rtol.elements[1])[2:half_rtol]
        ) / 2
    err_atol = [abs(norm(p) - r_outer) for p in midpoints_atol]
    err_rtol = [abs(norm(p) - r_outer) for p in midpoints_rtol]
    @test all(err_atol .< 1nm)
    @test all(uconvert.(NoUnits, err_rtol / r_outer) .<= 1e-4)
    @test round(vcount_atol / vcount_rtol) == 10

    # rtol=nothing is same as atol only
    c_atol_nothing = Cell("atol_nothing", nm)
    render!(c_atol_nothing, pa, GDSMeta(0); atol=1nm, rtol=nothing)
    @test c_atol.elements[1].p == c_atol_nothing.elements[1].p

    # Also works for Ellipse
    circ = Circle(1e3)
    circpoly_atol = to_polygons(circ)
    circpoly_rtol = to_polygons(circ; rtol=1e-4)
    @test round(length(points(circpoly_atol)) / length(points(circpoly_rtol))) == 10
end

@testitem "rtol_preserves_tight_curve_accuracy" setup = [CommonTestSetup] begin
    # π/2 Turn with R=1μm, atol=1nm, rtol=1e-4.
    # rtol·R = 1e-4 · 1μm = 100pm < 1nm = atol, so atol dominates.
    # Expected: segment counts identical to atol-alone rendering.
    pa = Path(μm)
    turn!(pa, π / 2, 1.0μm, Paths.Trace(0.2μm)) # R = 1μm
    c_atol = Cell("atol_only_tight", nm)
    render!(c_atol, pa, GDSMeta(0); atol=1nm)

    c_rtol = Cell("atol_rtol_tight", nm)
    render!(c_rtol, pa, GDSMeta(0); atol=1nm, rtol=1e-4)
    @test c_atol.elements[1].p == c_rtol.elements[1].p
end

@testitem "rtol_cpw_symmetry" setup = [CommonTestSetup] begin
    # A SimpleCPW Turn rendered with and without rtol must produce
    # valid polygons on both sides of the centerline; the coarsening applied
    # by rtol affects trace and gap symmetrically.
    pa = Path(μm)
    turn!(pa, π / 2, 1000.0μm, Paths.CPW(10.0μm, 6.0μm))

    # Baseline (atol only)
    c_atol = Cell("cpw_atol", nm)
    render!(c_atol, pa, GDSMeta(0); atol=1nm)

    # With rtol
    c_rtol = Cell("cpw_rtol", nm)
    render!(c_rtol, pa, GDSMeta(0); atol=1nm, rtol=1e-4)

    total_atol = sum(length(points(e)) for e in c_atol.elements)
    total_rtol = sum(length(points(e)) for e in c_rtol.elements)
    @test round(total_atol / total_rtol) == 10
    # CPW turns discretize based on maximum-radius curve, so all curves have the
    # same number of points. This is not a contract, so this behavior may change.
    @test length(points(c_rtol.elements[1])) == length(points(c_rtol.elements[2]))
end

@testitem "rtol_clamping_extreme_values" setup = [CommonTestSetup] begin
    # rtol ∈ {0, 1e-10, 1e-1, 1.0} applied to a fixed Turn.
    # Must: (a) not crash, (b) produce monotonic non-increasing vertex
    # counts as rtol grows, (c) tiny rtol ≈ atol-alone behavior.

    function vcount_with_rtol(rtol_val)
        c = Cell("turn_rtol_$(string(rtol_val))", nm)
        pa = Path(μm)
        turn!(pa, π / 2, 1000.0μm, Paths.Trace(10.0μm)) # R = 1mm
        if isnothing(rtol_val)
            render!(c, pa, GDSMeta(0); atol=1nm)
        else
            render!(c, pa, GDSMeta(0); atol=1nm, rtol=rtol_val)
        end
        vcount = sum(length(points(e)) for e in c.elements)
        @test vcount > 0
        return vcount
    end

    v_baseline = vcount_with_rtol(nothing)
    v_0 = vcount_with_rtol(0.0)
    v_tiny = vcount_with_rtol(1e-10)
    v_mid = vcount_with_rtol(1e-1)
    v_one = vcount_with_rtol(1.0)

    # Monotonic non-increasing as rtol grows.
    # rtol=0 and rtol=1e-10 should be effectively equivalent to rtol=nothing
    # because max(atol, rtol/curvature) collapses to atol.
    @test v_0 == v_baseline
    @test v_tiny == v_baseline
    # Larger rtol values must not INCREASE the count.
    @test v_mid < v_baseline
    @test v_one <= v_mid
end

@testitem "rtol_curvilinear_polygon_roundtrip" setup = [CommonTestSetup] begin
    # CurvilinearPolygon containing a Turn rendered through
    # `to_polygons(::CurvilinearPolygon; ..., rtol=...)` with
    # inner `discretize_curve` call.
    # Expected: vertex-count reduction on the rtol rendering should be
    # comparable to the direct Paths.Turn rendering.

    # Anchor points for a 90° turn of radius 1mm.
    R = 1000.0μm
    pp = [
        Point(0.0μm, 0.0μm),
        Point(R, 0.0μm),            # curve starts here (index 2)
        Point(0.0μm, R)             # curve ends here   (index 3)
    ]
    turn_seg = Paths.Turn(90°, R, α0=90°, p0=pp[2])
    cp = CurvilinearPolygon(pp, [turn_seg], [2])

    polys_atol = to_polygons(cp; atol=1nm)
    polys_rtol = to_polygons(cp; atol=1nm, rtol=1e-4)

    vcount_atol = length(points(polys_atol))
    vcount_rtol = length(points(polys_rtol))
    @test round(vcount_atol / vcount_rtol) == 10

    # Also verify that rtol=nothing preserves identity
    polys_nil = to_polygons(cp; atol=1nm, rtol=nothing)
    polys_none = to_polygons(cp; atol=1nm)
    @test points(polys_nil) == points(polys_none)
end

@testitem "rtol_known_segment_style_renderers" setup = [CommonTestSetup] begin
    function test_rtol_reduces(seg, sty)
        poly_atol = vcat(Polygon[], to_polygons(Paths.Node(seg, sty); atol=1nm))
        poly_rtol = vcat(Polygon[], to_polygons(Paths.Node(seg, sty); atol=1nm, rtol=1e-4))
        vcount_atol = sum(length(points(e)) for e in poly_atol)
        vcount_rtol = sum(length(points(e)) for e in poly_rtol)
        @test vcount_rtol > 0
        @test vcount_rtol < 0.5 * vcount_atol
    end

    turn_seg = Paths.Turn(pi / 2, 1000.0μm)
    turn_stys = [
        Paths.Trace(x -> 10.0μm + x / 100),
        Paths._withlength!(Paths.TaperTrace(10μm, 2μm), pathlength(turn_seg)),
        Paths.CPW(x -> 10.0μm + x / 100, x -> 6.0μm + x / 100),
        Paths._withlength!(Paths.TaperCPW(10μm, 6μm, 2μm, 1μm), pathlength(turn_seg)),
        Paths.Strands(2μm, 1μm, 1μm, 2)
    ]
    for sty in turn_stys
        test_rtol_reduces(turn_seg, sty)
    end

    pa = Path(μm)
    bspline!(
        pa,
        [Point(500.0μm, 100.0μm), Point(1000.0μm, 0.0μm)],
        0°,
        Paths.CPW(10μm, 6μm)
    )
    bspline_seg = pa[1].seg
    bspline_stys = [
        pa[1].sty,
        Paths._withlength!(Paths.TaperCPW(10μm, 6μm, 2μm, 1μm), pathlength(bspline_seg)),
        Paths.CPW(x -> 10.0μm + x / 100, x -> 6.0μm + x / 100),
        Paths.Trace(10μm),
        Paths.Trace(x -> 10μm + x / 100),
        Paths._withlength!(Paths.TaperTrace(10μm, 2μm), pathlength(bspline_seg)),
        Paths.Strands(2μm, 1μm, 1μm, 2)
    ]
    for sty in bspline_stys
        test_rtol_reduces(bspline_seg, sty)
    end

    for offset_seg in
        (Paths.offset(bspline_seg, 10μm), Paths.offset(bspline_seg, s -> 10μm + s / 100))
        pts_atol = DeviceLayout.discretize_curve(offset_seg, 1nm)
        pts_rtol = DeviceLayout.discretize_curve(offset_seg, 1nm; rtol=1e-4)
        @test length(pts_rtol) > 0
        @test length(pts_rtol) < 0.5 * length(pts_atol)
    end
end
