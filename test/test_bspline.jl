@testitem "BSpline" setup = [CommonTestSetup] begin
    po0 = Point(1.0μm, 1.0μm)
    po1 = Point(1000.0μm, -20.0μm)

    g0 = 100 * Point(1.0μm, 1.0μm) / sqrt(2)
    g1 = 100 * Point(0.6μm, -0.8μm)

    b = Paths.BSpline([po0, po1], g0, g1)

    # Segment properties
    @test Paths.arclength_to_t(b, Paths.t_to_arclength(b, 0.6)) ≈ 0.6 rtol = 1e-9
    @test Paths.Interpolations.gradient(b.r, 0.0)[1] ≈ g0 rtol = 1e-9
    @test Paths.Interpolations.gradient(b.r, 1.0)[1] ≈ g1 rtol = 1e-9
    @test Paths.curvatureradius(b, Paths.t_to_arclength(b, 0.0)) < zero(1.0μm)
    @test Paths.curvatureradius(b, Paths.t_to_arclength(b, 1.0)) < zero(1.0μm)

    # Reflect about y = 0, check the curvature radius changes
    g0 = 100 * Point(1.0μm, -1.0μm) / sqrt(2)
    g1 = 100 * Point(0.6μm, 0.8μm)
    b2 = Paths.BSpline([Point(1.0μm, -0.0μm), Point(1000.0μm, 20.0μm)], g0, g1)

    @test Paths.arclength_to_t(b, Paths.t_to_arclength(b, 0.6)) ≈ 0.6 rtol = 1e-9
    @test Paths.Interpolations.gradient(b2.r, 0.0)[1] ≈ g0 rtol = 1e-9
    @test Paths.Interpolations.gradient(b2.r, 1.0)[1] ≈ g1 rtol = 1e-9
    @test Paths.curvatureradius(b2, Paths.t_to_arclength(b2, 0.0)) > zero(1.0μm)
    @test Paths.curvatureradius(b2, Paths.t_to_arclength(b2, 1.0)) > zero(1.0μm)

    # Extending a Path
    path1 = Path(po0, α0=90°)
    bspline!(
        path1,
        [Point(1.0μm, 1001.0μm)],
        90°,
        Paths.SimpleCPW(20μm, 10μm),
        endpoints_speed=1.0μm
    )
    @test pathlength(path1) ≈ 1000μm rtol = 1e-9
    @test Paths.Interpolations.gradient(path1.nodes[1].seg.r, 0.0)[1] ≈ Point(0.0μm, 1.0μm) rtol =
        1e-9
    @test p1(path1) ≈ Point(1.0μm, 1001.0μm) rtol = 1e-9

    bspline!(
        path1,
        [Point(200.0μm, 500.0μm), po1],
        45°,
        Paths.TaperCPW(20μm, 10μm, 10μm, 5μm),
        endpoints_speed=100.0μm
    )
    @test Paths.Interpolations.gradient(path1.nodes[2].seg.r, 0.0)[1] ≈
          Point(0.0μm, 100.0μm) rtol = 1e-9
    @test Paths.Interpolations.gradient(path1.nodes[2].seg.r, 1.0)[1] ≈
          Point(100.0μm, 100.0μm) / sqrt(2) rtol = 1e-9

    # Constructor
    @test_throws ErrorException Paths.BSpline{Int}([Point(1, 1)], Point(2, 2), Point(3, 3))
    b2 = Paths.BSpline(
        [Point(1, 1), Point(1000, -20)],
        Point(1 / sqrt(2), 1 / sqrt(2)),
        Point(6, -8)
    )
    @test eltype(b2) == Float64

    # Convert
    b3 = convert(Paths.BSpline{typeof(1.0mm)}, b)
    @test eltype(b3) == typeof(1.0mm)

    # Split
    a1, a2 = Paths._split(b, 500μm)
    tsplit = Paths.arclength_to_t(b, 500μm)
    @test p0(a1) == po0
    @test p1(a1) == p0(a2)
    @test p1(a2) == po1
    @test a1(Paths.t_to_arclength(a1, 0.7)) ≈ b.r(tsplit * 0.7) atol = 1e-6 * μm
    @test a2(Paths.t_to_arclength(a2, 0.2)) ≈ b.r(tsplit + (1 - tsplit) * 0.2) atol =
        1e-6 * μm
    @test pathlength(a1) ≈ 500μm rtol = 1e-9
    @test pathlength(a2) ≈ pathlength(b) - 500μm rtol = 1e-9

    # Convert after split
    a2_conv = convert(Paths.BSpline{typeof(1.0mm)}, a2)
    @test p0(a2_conv) ≈ p0(a2)
    @test p1(a2_conv) ≈ p1(a2)

    # Splice
    b4 = Paths.BSpline(
        [Point(-100, -200), Point(200, 200), Point(100, -300), Point(500, 0)],
        Point(-100, 800),
        Point(500, 100)
    )

    pa2 = Paths.split(Paths.Node(b4, Paths.Trace(10)), 500)
    tsplit2 = Paths.arclength_to_t(b4, 500)
    a4 = pa2[end].seg
    c = Cell{Float64}("bsp")
    render!(c, pa2, GDSMeta(); atol=0.1)

    # Prepare manual splice transform for comparison
    translate = Translation(p0(b4) - p0(a4))
    rotate = Rotation(α0(b4) - α0(a4))
    splice_transform = Translation(p0(b4)) ∘ rotate ∘ Translation(-p0(b4)) ∘ translate

    Paths.splice!(pa2, 1)
    @test p0(pa2) == p0(b4)
    @test α0(pa2) == α0(b4)
    # Check an arbitrary point to make sure we have just rotated and translated a curve segment
    @test (pa2[1].seg)(Paths.t_to_arclength(pa2[1].seg, 0.2)) ≈
          splice_transform(b4.r(tsplit2 + (1 - tsplit2) * 0.2)) rtol = 1e-7

    # Also check reflection after splitting
    # And splitting with non-preferred unit
    pa3 = Path(10.0μm, 12.0μm; metadata=GDSMeta())
    turn!(pa3, 60°, 100μm, Paths.Trace(10μm))
    bspline!(pa3, [Point(200μm, 200μm)], 30°; endpoints_speed=200μm)
    splice!(pa3, 2, split(pa3[2], 100μm))
    cs = CoordinateSystem("test")
    addref!(cs, pa3, Point(-20, -20)μm, rot=45°, xrefl=true)
    tr = transformation(refs(cs)[1])
    csflat = flatten(cs)
    # Endpoints
    @test p0(elements(csflat)[2].seg) ≈ tr(p0(pa3[2].seg))
    @test p1(elements(csflat)[2].seg) ≈ tr(p1(pa3[2].seg))
    @test p0(elements(csflat)[3].seg) ≈ tr(p1(pa3[2].seg))
    @test p1(elements(csflat)[3].seg) ≈ tr(p1(pa3[3].seg))
    @test α0(elements(csflat)[2].seg) ≈ rotated_direction(α0(pa3[2].seg), tr)
    @test α1(elements(csflat)[2].seg) ≈ rotated_direction(α1(pa3[2].seg), tr)
    @test α0(elements(csflat)[3].seg) ≈ rotated_direction(α1(pa3[2].seg), tr)
    @test α1(elements(csflat)[3].seg) ≈ rotated_direction(α1(pa3[3].seg), tr)
    # Arbitrary points
    @test elements(csflat)[2].seg(50μm) ≈ tr(pa3[2].seg(50μm))
    @test elements(csflat)[3].seg(50μm) ≈ tr(pa3[3].seg(50μm))
    @test direction(elements(csflat)[2].seg, 50μm) ≈
          rotated_direction(direction(pa3[2].seg, 50μm), tr)
    @test direction(elements(csflat)[3].seg, 50μm) ≈
          rotated_direction(direction(pa3[3].seg, 50μm), tr)
end

@testitem "BSpline arclength cache" setup = [CommonTestSetup] begin
    import QuadGK
    ds(seg, t) = Paths.dsdt(t, seg.r)

    b = Paths.BSpline(
        [Point(1.0μm, 1.0μm), Point(1000.0μm, -20.0μm)],
        100 * Point(1.0μm, 1.0μm) / sqrt(2),
        100 * Point(0.6μm, -0.8μm)
    )
    L = pathlength(b)

    # Forward map is exact (matches an independent quadgk over the full and partial range)
    @test L ≈ QuadGK.quadgk(t -> ds(b, t), 0.0, 1.0)[1] rtol = 1e-9
    @test Paths.t_to_arclength(b, 0.37) ≈ QuadGK.quadgk(t -> ds(b, t), 0.0, 0.37)[1] rtol =
        1e-9

    # Inverse round-trips to full precision across the whole range (not just at t=0.6)
    for t in (1e-6, 0.01, 0.3, 0.5, 0.7, 0.99, 1 - 1e-6)
        @test Paths.arclength_to_t(b, Paths.t_to_arclength(b, t)) ≈ t rtol = 1e-9
    end

    # Cache is built lazily on first arclength query, and excluded from == / hash
    b_fresh = Paths.BSpline(copy(b.p), b.t0, b.t1)
    @test isnothing(b_fresh.reparam)
    pathlength(b_fresh)
    @test !isnothing(b_fresh.reparam)
    @test b_fresh == b
    @test hash(b_fresh) == hash(b)

    # Warm-cache results are bit-identical to the first (cold) evaluation
    s_mid = L / 3
    probe() = (
        pathlength(b),
        Paths.t_to_arclength(b, 0.42),
        Paths.arclength_to_t(b, s_mid),
        b(s_mid),
        direction(b, s_mid),
        Paths.curvatureradius(b, s_mid)
    )
    cold = probe()
    warm = probe()
    @test all(cold .== warm)

    # Endpoint and node queries are exact table lookups
    @test Paths.t_to_arclength(b, 1.0) === pathlength(b)
    rp = Paths._get_reparam(b)
    @test Paths.t_to_arclength(b, rp.ts[2]) === rp.ss[2]

    # NaN arclength fails attributably rather than deep inside Interpolations
    @test_throws DomainError Paths.arclength_to_t(b, NaN * μm)

    # copy shares `r`, so it also shares the warm cache; mutation drops only its own
    b_copy = copy(b)
    @test b_copy.reparam === b.reparam
    Paths.setp0!(b_copy, Point(0.0μm, 0.0μm))
    @test isnothing(b_copy.reparam)
    @test !isnothing(b.reparam)

    # Invalidation: rigid transforms preserve length; the cache is dropped and rebuilt
    let bt = Paths.BSpline(copy(b.p), b.t0, b.t1)
        pathlength(bt) # build cache
        Paths.setp0!(bt, Point(0.0μm, 0.0μm)) # translation
        @test isnothing(bt.reparam)
        @test pathlength(bt) ≈ L rtol = 1e-9
    end
    let bt = Paths.BSpline(copy(b.p), b.t0, b.t1)
        pathlength(bt)
        Paths.change_handedness!(bt) # reflection
        @test isnothing(bt.reparam)
        @test pathlength(bt) ≈ L rtol = 1e-9
    end
    let bt = Paths.BSpline(copy(b.p), b.t0, b.t1)
        pathlength(bt)
        Paths.setα0!(bt, α0(bt) + 30°) # rotation
        @test isnothing(bt.reparam)
        @test pathlength(bt) ≈ L rtol = 1e-9
    end

    # Split children get independent, initially-empty caches
    a1, a2 = Paths._split(b, 500μm)
    @test isnothing(a1.reparam)
    @test isnothing(a2.reparam)
    @test pathlength(a1) + pathlength(a2) ≈ L rtol = 1e-9

    # Strongly non-uniform ds/dt: exact forward map holds regardless of curvature
    b_curvy = Paths.BSpline(
        [Point(0.0μm, 0.0μm), Point(50.0μm, 100.0μm), Point(100.0μm, 0.0μm)],
        Point(100.0μm, 100.0μm),
        Point(100.0μm, -100.0μm)
    )
    @test Paths.t_to_arclength(b_curvy, 0.5) ≈
          QuadGK.quadgk(t -> ds(b_curvy, t), 0.0, 0.5)[1] rtol = 1e-9
    for t in (0.05, 0.25, 0.5, 0.75, 0.95)
        @test Paths.arclength_to_t(b_curvy, Paths.t_to_arclength(b_curvy, t)) ≈ t rtol =
            1e-9
    end
end

@testitem "BSpline offset cusps" setup = [CommonTestSetup] begin
    import Logging
    ### Maximum base curvature radius ~338um
    ## No cusp with trace width < 2*radius
    pa = Path()
    bspline!(
        pa,
        [Point(500.0μm, 500.0μm)],
        90°,
        Paths.Trace(600.0μm);
        endpoints_speed=800.0μm,
        auto_curvature=true
    )
    cp = Curvilinear.pathtopolys(pa[1])
    # No warning
    @test_logs min_level = Logging.Warn DeviceLayout.discretize_curve(cp.curves[2], 1.0nm)
    pts_no_cusp = DeviceLayout.discretize_curve(cp.curves[2], 1.0nm) # inner curve
    ## Cusp
    pa = Path()
    bspline!(
        pa,
        [Point(500.0μm, 500.0μm)],
        90°,
        Paths.Trace(680.0μm);
        endpoints_speed=800.0μm,
        auto_curvature=true
    )
    cp = Curvilinear.pathtopolys(pa[1])
    @test_logs (:warn, r"cusp") match_mode = :any DeviceLayout.discretize_curve(
        cp.curves[2],
        1.0nm
    )
    pts_cusp = DeviceLayout.discretize_curve(cp.curves[2], 1.0nm)
    # Number of points is not excessive
    @test length(pts_cusp) < 1.25 * length(pts_no_cusp)
    # Discretization is still ~ within tolerance
    @test all(
        is_sliver.(
            to_polygons(xor2d(to_polygons(cp), to_polygons(cp, atol=0.1nm))),
            atol=2.0nm
        )
    )
    ## Same but with GeneralTrace
    pa = Path()
    bspline!(
        pa,
        [Point(500.0μm, 500.0μm)],
        90°,
        Paths.Trace(x -> 680.0μm);
        endpoints_speed=800.0μm,
        auto_curvature=true
    )
    cp = Curvilinear.pathtopolys(pa[1])
    @test_logs (:warn, r"cusp") match_mode = :any DeviceLayout.discretize_curve(
        cp.curves[2],
        1.0nm
    )
    pts_cusp = DeviceLayout.discretize_curve(cp.curves[2], 1.0nm)
    # Number of points is not excessive
    @test length(pts_cusp) < 1.25 * length(pts_no_cusp)
    # Discretization is still ~ within tolerance
    @test all(
        is_sliver.(
            to_polygons(xor2d(to_polygons(cp), to_polygons(cp, atol=0.1nm))),
            atol=2.0nm
        )
    )

    ## Large ratio between base and offset radius without cusps
    pa = Path()
    bspline!(
        pa,
        [Point(500.0μm, 500.0μm)],
        90°,
        Paths.Trace(970μm);
        endpoints_speed=824μm # Base curvature roughly constant 500um, inner curve r ≈ 5um - 15um
    )
    cp = Curvilinear.pathtopolys(pa[1])
    @test all(
        is_sliver.(
            to_polygons(xor2d(to_polygons(cp), to_polygons(cp, atol=0.1nm))),
            atol=2.0nm
        )
    )
end

@testitem "BSpline approximation" setup = [CommonTestSetup] begin
    pa = Path(Point(0.0, 0.0)nm, α0=90°)
    bspline!(
        pa,
        [Point(1000.0μm, 1000.0μm), Point(2500.0μm, 2500.0μm)],
        -90°,
        Paths.SimpleCPW(20μm, 10μm)
    )
    bspline!(pa, [Point(100.0μm, 100.0μm)], 270°, Paths.TaperCPW(20μm, 10μm, 2μm, 1μm))
    turn!(pa, 90°, 100μm, Paths.TaperCPW(2μm, 1μm, 20μm, 10μm))
    turn!(pa, -90°, 100μm, Paths.CPW(20μm, 10μm))
    curv = vcat(pathtopolys(pa)...)
    # First BSpline is hardest, maybe due to intermediate waypoint?
    lims = [45, 45, 20, 20, 9, 9, 9, 9]
    for (poly, lim) in zip(curv, lims)
        for curve in poly.curves
            approx = Paths.bspline_approximation(curve)
            @test length(approx.segments) < lim
            @test Paths.arclength(approx) ≈ Paths.arclength(curve) atol = 1nm
        end
    end
    # Relaxed tolerance
    approx = Paths.bspline_approximation(curv[1].curves[1], atol=100.0nm)
    @test length(approx.segments) < 20
    # Non-offset curve approximation
    approx = Paths.bspline_approximation(pa[4].seg)
    @test length(approx.segments) < 9
    # Offset curvatureradius
    g_fd(c, s, ds=10.0nm) = (c(s + ds / 2) - c(s - ds / 2)) / ds
    h_fd(c, s, ds=10.0nm) = g_fd(s_ -> g_fd(c, s_, ds), s, ds)
    curvatureradius_fd(c, s, ds=10.0nm) = begin
        g = g_fd(c, s, ds)
        h = h_fd(c, s, ds)
        ((g.x^2 + g.y^2)^(3 // 2)) / (g.x * h.y - g.y * h.x)
    end # assumes constant d(arclength)/ds
    # For BSplines, curvature radius calculation is only approximate, but not bad
    c = curv[1].curves[1] # ConstantOffset BSpline
    @test abs(curvatureradius_fd(c, 10μm) - Paths.curvatureradius(c, 10μm)) < 1nm
    c = curv[3].curves[1] # GeneralOffset BSpline
    @test abs(curvatureradius_fd(c, 10μm) - Paths.curvatureradius(c, 10μm)) < 50nm
    c = curv[5].curves[1] # GeneralOffset Turn
    # Paths.curvatureradius is exact for Turn offsets
    @test abs(curvatureradius_fd(c, 10μm) - Paths.curvatureradius(c, 10μm)) < 1nm
    approx = Paths.bspline_approximation(c, atol=100.0nm)
    pts = DeviceLayout.discretize_curve(c, 100.0nm)
    pts_approx = vcat(DeviceLayout.discretize_curve.(approx.segments, 100.0nm)...)
    poly = Polygon([pts; reverse(pts_approx)])
    @test abs(Polygons.area(poly) / perimeter(poly)) < 100nm # It's actually ~25nm but the guarantee is ~< tolerance
    c = curv[8].curves[1] # ConstantOffset Turn
    @test Paths.curvatureradius(c, 10μm) == sign(c.seg.α) * c.seg.r - c.offset
    @test curvatureradius_fd(c, 10μm) ≈ Paths.curvatureradius(c, 10μm) atol = 1nm
    # Direct ConstantOffset discretization is bypassed by rendering; check its t_scale correction.
    co_pts = DeviceLayout.discretize_curve(c, 100.0nm)
    co_approx = vcat(
        DeviceLayout.discretize_curve.(
            Paths.bspline_approximation(c, atol=100.0nm).segments,
            100.0nm
        )...
    )
    co_poly = Polygon([co_pts; reverse(co_approx)])
    @test abs(Polygons.area(co_poly) / perimeter(co_poly)) < 100nm

    # Failure due to self-intersection
    pa2 = Path(Point(0.0, 0.0)nm, α0=90°)
    bspline!(
        pa2,
        [Point(-1000.0μm, 1000.0μm), Point(500.0μm, 500.0μm)],
        0°,
        Paths.SimpleCPW(20μm, 10μm)
    )
    cps = vcat(pathtopolys(pa2)...)
    @test_logs (:warn, r"Maximum error") Paths.bspline_approximation(cps[1].curves[1])
end

@testitem "BSpline optimization" setup = [CommonTestSetup] begin
    ## 90 degree turn
    pa = Path() # auto_speed
    bspline!(pa, [Point(100μm, 100μm)], 90°, Paths.Trace(1μm); auto_speed=true)
    pa2 = Path() # auto_curvature, fixed speed
    bspline!(
        pa2,
        [Point(100μm, 100μm)],
        90°,
        Paths.Trace(1μm);
        endpoints_speed=180μm,
        auto_curvature=true
    ) # Close to but not optimal
    pa3 = Path() # auto_speed, auto_curvature
    bspline!(
        pa3,
        [Point(100μm, 100μm)],
        90°,
        Paths.Trace(1μm);
        auto_speed=true,
        auto_curvature=true
    )
    b1 = pa3[1].seg
    # Same thing again
    pa3 = Path() # auto_speed, auto_curvature
    bspline!(
        pa3,
        [Point(100μm, 100μm)],
        90°,
        Paths.Trace(1μm);
        auto_speed=true,
        auto_curvature=true
    )
    b2 = pa3[1].seg
    @test b1 == b2
    @test hash(b1) == hash(b2)
    # Different result without auto_curvature
    pa3_nocurv = Path() # auto_speed, auto_curvature
    bspline!(pa3_nocurv, [Point(100μm, 100μm)], 90°, Paths.Trace(1μm); auto_speed=true)
    b3 = pa3_nocurv[1].seg
    @test b3 != b1
    @test hash(b3) != hash(b1)

    pa_turn = Path() # For comparison
    turn!(pa_turn, 90°, 100μm, Paths.Trace(1μm))
    # auto_speed is close to a circle (about 140nm max distance)
    @test Paths.norm(pa_turn[1].seg(π / 4 * 100μm) - pa[1].seg.r(0.5)) < 0.141μm
    @test abs(pathlength(pa) - 100μm * pi / 2) < 100nm # |-92.695nm| < 100nm
    # Equal tangents -- symmetric optimization was used
    @test Paths._symmetric_optimization(pa[1].seg)
    @test Paths.norm(pa[1].seg.t0) == Paths.norm(pa[1].seg.t1)
    # Less penalty when auto_speed is used
    @test Paths._int_dκ2(pa2[1].seg, 100μm) > Paths._int_dκ2(pa3[1].seg, 100μm)
    # Curvature is zero at endpoints
    @test Paths.signed_curvature(pa2[1].seg, 0nm) ≈ 0 / nm atol = 1e-9 / nm
    @test Paths.signed_curvature(pa2[1].seg, pathlength(pa2)) ≈ 0 / nm atol = 1e-9 / nm
    @test Paths.signed_curvature(pa3[1].seg, 0nm) ≈ 0 / nm atol = 1e-9 / nm
    @test Paths.signed_curvature(pa3[1].seg, pathlength(pa2)) ≈ 0 / nm atol = 1e-9 / nm
    # Speed is preserved when only curvature is optimized
    @test Paths.norm(Paths.Interpolations.gradient(pa2[1].seg.r, 0)[1]) == 180μm
    @test Paths.norm(Paths.Interpolations.gradient(pa2[1].seg.r, 1)[1]) == 180μm

    ## Scale independence
    pa_small = Path()
    bspline!(pa_small, [Point(1μm, 1μm)], 90°, Paths.Trace(1μm); auto_speed=true)
    @test pa_small[1].seg.t0 ≈ pa[1].seg.t0 / 100

    pa3_small = Path()
    bspline!(
        pa3_small,
        [Point(1μm, 1μm)],
        90°,
        Paths.Trace(1μm);
        auto_speed=true,
        auto_curvature=true
    )
    @test pa3_small[1].seg.t0 ≈ pa3[1].seg.t0 / 100

    ## 180 degree symmetry
    pa_snake = Path()
    bspline!(
        pa_snake,
        [Point(100μm, 20μm), Point(200μm, 80μm), Point(300μm, 100μm)],
        0°,
        Paths.Trace(1μm);
        auto_speed=true
    )
    @test Paths._symmetric_optimization(pa_snake[1].seg)

    ## Nonzero curvature
    @test Paths._last_curvature(pa_turn) == 1 / (100μm)
    bspline!(pa_turn, [Point(0μm, 200μm)], 180°; auto_speed=true, auto_curvature=true)
    @test Paths.signed_curvature(pa_turn[2].seg, 0nm) ≈ 1 / (100μm)
    @test Paths.signed_curvature(pa_turn[2].seg, pathlength(pa_turn[2])) ≈ 1 / (100μm)

    ## Manual curvature
    pa4 = Path()
    bspline!(
        pa4,
        [Point(0μm, 200μm)],
        -90°,
        Paths.Trace(1μm);
        auto_speed=true,
        endpoints_curvature=1 / (50μm)
    )
    @test Paths.signed_curvature(pa4[1].seg, 0nm) ≈ 1 / (50μm)
    @test Paths.signed_curvature(pa4[1].seg, pathlength(pa4[1])) ≈ 1 / (50μm)

    ## Multiple waypoints
    bspline!(
        pa4,
        [Point(100μm, 100μm), Point(200μm, 200μm), Point(0μm, 0μm)],
        -90°,
        Paths.Trace(1μm);
        endpoints_speed=160μm,
        auto_curvature=true
    )
    @test Paths.signed_curvature(pa4[2].seg, 0nm) ≈ 1 / (50μm)
    @test Paths.signed_curvature(pa4[2].seg, pathlength(pa4[2])) ≈ 1 / (50μm)
    @test Paths.norm(Paths.Interpolations.gradient(pa4[2].seg.r, 0)[1]) ≈ 160μm
    @test Paths.norm(Paths.Interpolations.gradient(pa4[2].seg.r, 1)[1]) ≈ 160μm

    ## Renders successfully
    # (discretization doesn't see zero curvature and think it can just skip the whole thing)
    pa5 = Path()
    bspline!(
        pa5,
        [Point(0μm, 200μm)],
        180°,
        Paths.Trace(1μm);
        auto_speed=true,
        auto_curvature=true
    )
    c = Cell("test")
    render!(c, pa5, GDSMeta())
    @test length(elements(c)[1].p) > 500 # 856, but discretization is subject to change

    ## Different stop/start boundary conditions
    pa6 = Path()
    bspline!(
        pa6,
        [Point(100μm, 100μm), Point(200μm, 200μm), Point(0μm, 0μm)],
        -90°,
        Paths.Trace(1μm);
        endpoints_speed=[160μm, 120μm],
        endpoints_curvature=[1 / (50μm), 0 / (50μm)]
    )
    @test Paths.signed_curvature(pa6[1].seg, 0nm) ≈ 1 / (50μm)
    @test Paths.signed_curvature(pa6[1].seg, pathlength(pa6[1])) ≈ zero(1 / (50μm)) atol =
        1e-15 / nm
    @test Paths.norm(Paths.Interpolations.gradient(pa6[1].seg.r, 0)[1]) ≈ 160μm
    @test Paths.norm(Paths.Interpolations.gradient(pa6[1].seg.r, 1)[1]) ≈ 120μm

    ### Unbounded optimization (issue #135)
    pa = Path(Point(-5.8, 3.9)mm, α0=-90°)
    @test_logs (:warn, r"increasing speed without bound") bspline!(
        pa,
        [Point(-0.55, 1.8)mm],
        180°,
        Paths.Trace(1μm),
        auto_speed=true
    )
end
