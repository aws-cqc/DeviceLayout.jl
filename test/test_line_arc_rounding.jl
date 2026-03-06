@testitem "Line-arc rounding" setup = [CommonTestSetup] begin
    using LinearAlgebra
    using DeviceLayout.Curvilinear: edge_type_at_vertex

    # 24×16μm rectangle with 13 arc features covering various arc sweeps,
    # angles between straight lines, and tangency types (internal/external).
    #
    # Exterior (10 arcs):
    #   Bottom (y=0): B1 130° bump, B2 90° notch, B3 60° arc notch
    #   Right (x=W):  R1 270° notch, R2 180° notch
    #   Top (y=H):    T1 60° arc bump, T2 90° bump, T3 120° arc tab
    #   Left (x=0):   L1 270° bump, L2 180° bump
    #
    # Interior holes (3 pie-slice arcs, forming a halo via CurvilinearRegion):
    #   H1 90° arc  at (12, 8)μm r=3μm    (like T2)
    #   H2 60° arc  at (7, 8)μm  r=2.5μm  (like T1)
    #   H3 120° arc at (18, 8)μm r=2μm    (like T3)

    W = 24.0μm
    H = 16.0μm

    # Build a feature where a straight line from edge_pt at line_angle
    # meets a clockwise arc (centered at edge_pt) sweeping arc_sweep back to the edge.
    function make_edge_feature(edge_pt, line_angle, arc_sweep, r)
        pk = edge_pt + Point(r * cos(line_angle), r * sin(line_angle))
        end_angle = line_angle - arc_sweep
        rt = edge_pt + Point(r * cos(end_angle), r * sin(end_angle))
        α0 = atan((pk - edge_pt).y, (pk - edge_pt).x) - π / 2
        arc = Paths.Turn(-arc_sweep, r, p0=pk, α0=α0)
        return (; left=edge_pt, peak=pk, right=rt, arc=arc)
    end

    # Bottom edge
    b1 = make_edge_feature(Point(2.0μm, 0.0μm), 130.0 * π / 180, 130.0 * π / 180, 1.5μm)
    b2 = make_edge_feature(Point(7.0μm, 0.0μm), π / 2, π / 2, 2.0μm)
    b3 = make_edge_feature(Point(12.0μm, 0.0μm), π / 3, π / 3, 2.0μm)

    # Right edge: R1 270° notch (center inside polygon)
    r1_r = 1.0μm
    r1_cy = 4.0μm
    r1_bot = Point(W, r1_cy - r1_r)
    r1_top = Point(W, r1_cy + r1_r)
    r1_O = Point(W - r1_r, r1_cy)
    r1_R = r1_r * sqrt(2)
    r1_α0 = atan((r1_bot - r1_O).y, (r1_bot - r1_O).x) - π / 2
    r1_arc = Paths.Turn(-3π / 2, r1_R, p0=r1_bot, α0=r1_α0)

    # Right edge: R2 180° notch
    r2_r = 1.0μm
    r2_cy = 11.0μm
    r2_bot = Point(W, r2_cy - r2_r)
    r2_top = Point(W, r2_cy + r2_r)
    r2_arc = Paths.Turn(-π, r2_r, p0=r2_bot, α0=π)

    # Top edge (right to left): T1 60° arc bump (120° between lines)
    t1_r = 1.5μm
    t1_x = 18.0μm
    t1_right = Point(t1_x + t1_r, H)
    t1_center = Point(t1_x, H)
    t1_peak = t1_center + Point(t1_r * cos(π / 3), t1_r * sin(π / 3))
    t1_left = t1_center
    t1_α0 = atan((t1_right - t1_center).y, (t1_right - t1_center).x) + π / 2
    t1_arc = Paths.Turn(π / 3, t1_r, p0=t1_right, α0=t1_α0)

    # Top edge: T2 90° bump
    t2_r = 2.0μm
    t2_x = 12.0μm
    t2_right = Point(t2_x + t2_r, H)
    t2_center = Point(t2_x, H)
    t2_peak = Point(t2_x, H + t2_r)
    t2_left = Point(t2_x, H)
    t2_α0 = atan((t2_right - t2_center).y, (t2_right - t2_center).x) + π / 2
    t2_arc = Paths.Turn(π / 2, t2_r, p0=t2_right, α0=t2_α0)

    # Top edge: T3 120° arc tab (60° between lines)
    t3_r = 2.0μm
    t3_x = 4.0μm
    t3_right = Point(t3_x + t3_r, H)
    t3_center = Point(t3_x, H)
    t3_peak = t3_center + Point(t3_r * cos(2π / 3), t3_r * sin(2π / 3))
    t3_left = Point(t3_x, H)
    t3_α0 = atan((t3_right - t3_center).y, (t3_right - t3_center).x) + π / 2
    t3_arc = Paths.Turn(2π / 3, t3_r, p0=t3_right, α0=t3_α0)

    # Left edge: L1 270° bump (center outside polygon, protruding leftward)
    l1_r = 1.0μm
    l1_cy = 12.0μm
    l1_top = Point(0.0μm, l1_cy + l1_r)
    l1_bot = Point(0.0μm, l1_cy - l1_r)
    l1_O = Point(-l1_r, l1_cy)
    l1_R = l1_r * sqrt(2)
    l1_α0 = atan((l1_top - l1_O).y, (l1_top - l1_O).x) + π / 2
    l1_arc = Paths.Turn(3π / 2, l1_R, p0=l1_top, α0=l1_α0)

    # Left edge: L2 180° bump (protruding leftward)
    l2_r = 0.5μm
    l2_cy = 5.0μm
    l2_top = Point(0.0μm, l2_cy + l2_r)
    l2_bot = Point(0.0μm, l2_cy - l2_r)
    l2_arc = Paths.Turn(π, l2_r, p0=l2_top, α0=π)

    # H1: 90° pie-slice hole at (12, 8)
    hole_center = Point(12.0μm, 8.0μm)
    hole_r = 3.0μm
    hole_p1 = hole_center + Point(hole_r, 0.0μm)   # (15, 8)
    hole_p2 = hole_center + Point(0.0μm, hole_r)    # (12, 11)
    hole_α0 = π / 2  # tangent at hole_p1 for counterclockwise arc centered at hole_center
    hole_arc = Paths.Turn(π / 2, hole_r, p0=hole_p1, α0=hole_α0)

    # Verify arc endpoints
    @test isapprox(Paths.p1(hole_arc), hole_p2, atol=0.1nm)
    @test isapprox(Paths.p1(b1.arc), b1.right, atol=0.1nm)
    @test isapprox(Paths.p1(b2.arc), b2.right, atol=0.1nm)
    @test isapprox(Paths.p1(b3.arc), b3.right, atol=0.1nm)
    @test isapprox(Paths.p1(r1_arc), r1_top, atol=0.1nm)
    @test isapprox(Paths.p1(r2_arc), r2_top, atol=0.1nm)
    @test isapprox(Paths.p1(t1_arc), t1_peak, atol=0.1nm)
    @test isapprox(Paths.p1(t2_arc), t2_peak, atol=0.1nm)
    @test isapprox(Paths.p1(t3_arc), t3_peak, atol=0.1nm)
    @test isapprox(Paths.p1(l1_arc), l1_bot, atol=0.1nm)
    @test isapprox(Paths.p1(l2_arc), l2_bot, atol=0.1nm)

    # Counterclockwise polygon: 30 vertices, 10 arcs, 20 line-arc corners
    pts = [
        Point(0.0μm, 0.0μm),  # 1
        b1.left,              # 2
        b1.peak,              # 3  [arc: 3→4]
        b1.right,             # 4
        b2.left,              # 5
        b2.peak,              # 6  [arc: 6→7]
        b2.right,             # 7
        b3.left,              # 8
        b3.peak,              # 9  [arc: 9→10]
        b3.right,             # 10
        Point(W, 0.0μm),      # 11
        r1_bot,               # 12 [arc: 12→13]
        r1_top,               # 13
        r2_bot,               # 14 [arc: 14→15]
        r2_top,               # 15
        Point(W, H),          # 16
        t1_right,             # 17 [arc: 17→18]
        t1_peak,              # 18
        t1_left,              # 19
        t2_right,             # 20 [arc: 20→21]
        t2_peak,              # 21
        t2_left,              # 22
        t3_right,             # 23 [arc: 23→24]
        t3_peak,              # 24
        t3_left,              # 25
        Point(0.0μm, H),      # 26
        l1_top,               # 27 [arc: 27→28]
        l1_bot,               # 28
        l2_top,               # 29 [arc: 29→30]
        l2_bot                # 30
    ]
    arcs = [b1.arc, b2.arc, b3.arc, r1_arc, r2_arc, t1_arc, t2_arc, t3_arc, l1_arc, l2_arc]
    arc_idx = [3, 6, 9, 12, 14, 17, 20, 23, 27, 29]
    cp = CurvilinearPolygon(pts, arcs, arc_idx)

    # Straight corners have both edges straight
    for i in [1, 2, 5, 8, 11, 16, 19, 22, 25, 26]
        e = edge_type_at_vertex(cp, i)
        @test e.incoming == :straight
        @test e.outgoing == :straight
    end

    # Line-arc corners: arc outgoing
    for (vtx, arc_ref) in [
        (3, b1.arc),
        (6, b2.arc),
        (9, b3.arc),
        (12, r1_arc),
        (14, r2_arc),
        (17, t1_arc),
        (20, t2_arc),
        (23, t3_arc),
        (27, l1_arc),
        (29, l2_arc)
    ]
        @test edge_type_at_vertex(cp, vtx).outgoing == arc_ref
    end

    # Line-arc corners: arc incoming
    for (vtx, arc_ref) in [
        (4, b1.arc),
        (7, b2.arc),
        (10, b3.arc),
        (13, r1_arc),
        (15, r2_arc),
        (18, t1_arc),
        (21, t2_arc),
        (24, t3_arc),
        (28, l1_arc),
        (30, l2_arc)
    ]
        @test edge_type_at_vertex(cp, vtx).incoming == arc_ref
    end

    # Renders without rounding
    cs = CoordinateSystem("no_round", nm)
    @test_nowarn place!(cs, cp, GDSMeta())
    @test_nowarn render!(Cell("no_round", nm), cs)

    # Apply rounding
    fillet_r = 0.3μm
    rounded = to_polygons(cp, Rounded(fillet_r))
    rounded_pts = points(rounded)
    @test length(rounded_pts) > 30

    # G1 continuity: no angle jump exceeds the circular_arc discretization step.
    # dθ_max = 2 * sqrt(2 * atol / r_min) is the max step from circular_arc.
    dθ_max = 2 * sqrt(2 * ustrip(nm, 1.0nm) / ustrip(nm, fillet_r))
    n = length(rounded_pts)
    for i in eachindex(rounded_pts)
        e1 = rounded_pts[i] - rounded_pts[mod1(i - 1, n)]
        e2 = rounded_pts[mod1(i + 1, n)] - rounded_pts[i]
        if norm(e1) > 0.01nm && norm(e2) > 0.01nm
            cos_a = clamp((e1.x * e2.x + e1.y * e2.y) / (norm(e1) * norm(e2)), -1.0, 1.0)
            @test acos(cos_a) < 1.1 * dθ_max
        end
    end

    # Renders after rounding
    @test_nowarn render!(Cell("rounded", nm), let
        cs = CoordinateSystem("r", nm)
        place!(cs, rounded, GDSMeta())
        cs
    end)

    # Fillet radius larger than arc radius — should not error
    big_rounded = to_polygons(cp, Rounded(5.0μm))
    @test length(points(big_rounded)) > 0

    # CurvilinearRegion with three pie-slice holes (halo)

    # Hole 1: H1 90° arc (like T2) at (12, 8)
    hole1_pts = [hole_center, hole_p1, hole_p2]
    hole1_cp = CurvilinearPolygon(hole1_pts, [hole_arc], [2])

    @test edge_type_at_vertex(hole1_cp, 1).incoming == :straight
    @test edge_type_at_vertex(hole1_cp, 1).outgoing == :straight
    @test edge_type_at_vertex(hole1_cp, 2).outgoing == hole_arc
    @test edge_type_at_vertex(hole1_cp, 3).incoming == hole_arc

    # Hole 2: H2 60° arc (like T1) at (7, 8), r=2.5μm
    hole2_center = Point(7.0μm, 8.0μm)
    hole2_r = 2.5μm
    hole2_p1 = hole2_center + Point(hole2_r, 0.0μm)
    hole2_p2 = hole2_center + Point(hole2_r * cos(π / 3), hole2_r * sin(π / 3))
    hole2_arc = Paths.Turn(π / 3, hole2_r, p0=hole2_p1, α0=π / 2)
    @test isapprox(Paths.p1(hole2_arc), hole2_p2, atol=0.1nm)
    hole2_cp = CurvilinearPolygon([hole2_center, hole2_p1, hole2_p2], [hole2_arc], [2])

    # Hole 3: H3 120° arc (like T3) at (18, 8), r=2μm
    hole3_center = Point(18.0μm, 8.0μm)
    hole3_r = 2.0μm
    hole3_p1 = hole3_center + Point(hole3_r, 0.0μm)
    hole3_p2 = hole3_center + Point(hole3_r * cos(2π / 3), hole3_r * sin(2π / 3))
    hole3_arc = Paths.Turn(2π / 3, hole3_r, p0=hole3_p1, α0=π / 2)
    @test isapprox(Paths.p1(hole3_arc), hole3_p2, atol=0.1nm)
    hole3_cp = CurvilinearPolygon([hole3_center, hole3_p1, hole3_p2], [hole3_arc], [2])

    region = CurvilinearRegion(cp, [hole1_cp, hole2_cp, hole3_cp])

    # Renders without rounding
    cs_region = CoordinateSystem("region_no_round", nm)
    @test_nowarn place!(cs_region, region, GDSMeta())
    @test_nowarn render!(Cell("region_no_round", nm), cs_region)

    # Apply rounding to region (returns a ClippedPolygon)
    rounded_region = to_polygons(region, Rounded(fillet_r))
    region_polys = to_polygons(rounded_region)
    @test length(region_polys) > 0

    # Renders after rounding
    @test_nowarn render!(
        Cell("region_rounded", nm),
        let
            cs = CoordinateSystem("rr", nm)
            place!(cs, rounded_region, GDSMeta())
            cs
        end
    )
end
