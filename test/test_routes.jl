@testitem "Routes" setup = [CommonTestSetup] begin
    # Break traversal into two routing segments
    p_start = Point(10.0, 20.0)
    p_end = Point(100.0, 200.0)
    α_start = 90°
    α_end = 90°
    r = Route(
        Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=200),
        p_start,
        p_end,
        α_start,
        α_end
    )
    sty = Paths.CPW(10.0, 6.0)
    pa = Path(r, sty)
    @test p0(pa) == p_start
    @test p1(pa) == p_end
    @test α0(pa) == α_start
    @test α1(pa) == α_end

    p_end_bad = Point(20.0, 200.0)
    r = Route(
        Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=200),
        p_start,
        p_end_bad,
        α_start,
        α_end
    )
    @test_logs (:error, r"Could not automatically route") match_mode = :any pa =
        Path(r, sty)
    @test length(pa) > 0 # Partial/best-effort route was drawn

    r = Route(
        Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=200),
        p_start,
        p_end,
        α_start,
        pi
    )
    @test_logs (:error, r"Could not automatically route") (pa = Path(r, sty))

    r = Route(
        Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=200),
        p_start,
        p_end,
        α_start,
        0
    )
    pa = Path(r, sty)
    @test p1(pa) ≈ p_end
    @test α1(pa) == 0

    r = Route(
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=200),
        p_start,
        p_end,
        α_start,
        π / 4
    )
    pa = Path(r, sty)
    @test p1(pa) ≈ p_end
    @test α1(pa) == pi / 4

    # Use explicit waypoints
    p_start = Point(10.0, 20.0)
    p_end = Point(100.0, 200.0)
    α_start = 90°
    α_end = 0°
    waypoints = [Point(50.0, 40.0), Point(80.0, 90.0)]
    r2 = Route(
        Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=200),
        p_start,
        p_end,
        α_start,
        α_end,
        waypoints=waypoints
    )
    pa = Path(r2, sty)
    @test p0(pa) == p_start
    @test p1(pa) == p_end
    @test p1(pa.nodes[2].seg) == waypoints[1]
    @test α0(pa) == α_start
    @test α1(pa) == α_end

    # Automatically snake to endpoint after last waypoint
    p_start = Point(10.0, 20.0)
    p_end = Point(100.0, 200.0)
    α_start = 90°
    α_end = 0°
    waypoints = [Point(50.0, 40.0)]
    r2 = Route(
        Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=200),
        p_start,
        p_end,
        α_start,
        α_end,
        waypoints=waypoints
    )
    pa = Path(r2, sty)
    @test p0(pa) == p_start
    @test p1(pa) == p_end
    @test p1(pa.nodes[2].seg) == waypoints[1]
    @test p1(pa.nodes[4].seg) == Point(75.0, 120.0)
    @test α0(pa) == α_start
    @test α1(pa) == α_end

    # Use BSplineRouting
    r3 = Route(
        Paths.BSplineRouting(endpoints_speed=2000),
        p_start,
        p_end,
        α_start,
        α_end,
        waypoints=waypoints
    )
    pa = Path(r3, sty)
    @test p0(pa) == p_start
    @test p1(pa) ≈ p_end
    @test α0(pa) == α_start
    @test α1(pa) == α_end

    # Use StraightAnd45 with incompatible waypoints
    r4 = Route(
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=20),
        p_start,
        p_end,
        α_start,
        α_end,
        waypoints=waypoints
    )
    @test_logs (:error, r"can't be reached") (pa = Path(r4, sty))

    # Use StraightAnd45
    p_end = Point(200, 150)
    waypoints = [Point(40.0, 80.0), Point(100.0, 100.0), Point(150.0, 125.0)]
    r4 = Route(
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=20),
        p_start,
        p_end,
        α_start,
        α_end,
        waypoints=waypoints
    )
    pa = Path(r4, sty)
    @test p0(pa) == p_start
    @test p1(pa) == p_end
    @test p1(pa.nodes[3].seg) == waypoints[1]
    @test α0(pa) == α_start
    @test α1(pa) == α_end

    crule = Paths.CompoundRouteRule([
        Paths.StraightAnd90(min_bend_radius=20, max_bend_radius=100),
        Paths.BSplineRouting(endpoints_speed=2000),
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=100)
    ])
    r5 = Route(
        crule,
        p_start,
        Point(50, 90),
        α_start,
        135°,
        waypoints=[Point(100, 45), Point(100, 70)],
        waydirs=[0, π]
    )
    pa = Path(r5, [sty, sty, sty])
    @test p1(pa) ≈ Point(50, 90)
    @test p1(pa.nodes[2].seg) ≈ Point(100, 45)
    @test α1(pa.nodes[2].seg) == 0
    @test p1(pa.nodes[3].seg) ≈ Point(100, 70)
    @test α1(pa.nodes[3].seg) == 180°
    @test α1(pa) == 135°

    # StraightAnd45 with automatic snake after waypoints
    p_end = Point(200, 150)
    waypoints = [Point(40.0, 80.0), Point(100.0, 100.0)]
    r6 = Route(
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=20),
        p_start,
        p_end,
        α_start,
        α_end,
        waypoints=waypoints
    )
    pa = Path(r6, sty)
    @test p0(pa) == p_start
    @test p1(pa) == p_end
    @test p1(pa.nodes[3].seg) == waypoints[1]
    @test p1(pa.nodes[9].seg) == Point(150.0, 125.0)
    @test α0(pa) == α_start
    @test α1(pa) == α_end

    # With 2 same-direction turns
    p_end = Point(200, 150)
    waypoints = [Point(40.0, 80.0), Point(100.0, 100.0)]
    r7 = Route(
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=20),
        p_start,
        p_end,
        α_start,
        90°,
        waypoints=waypoints
    )
    pa = Path(r7, sty)
    @test p0(pa) == p_start
    @test p1(pa) == p_end
    @test p1(pa.nodes[3].seg) == waypoints[1]
    @test p1(pa.nodes[9].seg) == Point(180.0, 150.0) + 20 * Point(1, -1) / sqrt(2)
    @test α0(pa) == α_start
    @test α1(pa) == 90°

    r7 = Route(
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=50),
        p_start,
        p_end,
        α_start,
        90°,
        waypoints=waypoints
    )
    pa2 = Path(r7, sty)
    @test pathlength(pa2) < pathlength(pa)

    # Should run without error
    pa = Path(Point(0.0nm, 0.0nm))
    route!(pa, Point(500μm, 500μm), 90°, Paths.StraightAnd90(), Paths.SimpleCPW(10μm, 6μm))

    # Waypoint inline with endpoint
    p_start = Point(0.0, 0.0)
    p_end = Point(50, 150)
    α_start = 0°
    α_end = 90°
    waypoints = [Point(50.0, 75.0)]
    waydirs = [90°]
    r7 = Route(
        Paths.StraightAnd45(min_bend_radius=20, max_bend_radius=20),
        p_start,
        p_end,
        α_start,
        α_end,
        waypoints=waypoints,
        waydirs=waydirs
    )
    sty = Paths.Trace(4)
    pa = Path(r7, sty)

    # Convenience constructor for fixed turn radius
    @test Paths.StraightAnd45(10.0).min_bend_radius ==
          Paths.StraightAnd45(10.0).max_bend_radius
end
