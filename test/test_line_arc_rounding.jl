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
    check_g1_continuity(rounded_pts, dθ_max)

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

    # Apply rounding to region
    region_polys = to_polygons(region, Rounded(fillet_r))
    @test length(region_polys) > 0

    # SolidModel segment version: rounded_corner_segment_line_arc
    # Verify that the Turn-returning variant produces tangent points and
    # endpoints consistent with the discretized rounded_corner_line_arc.

    import DeviceLayout.SolidModels: rounded_corner_segment_line_arc
    using DeviceLayout.Curvilinear: rounded_corner_line_arc

    n_pts = length(pts)
    for i = 1:n_pts
        edge = edge_type_at_vertex(cp, i)
        is_line_arc = (edge.incoming == :straight) != (edge.outgoing == :straight)
        !is_line_arc && continue

        arc_is_outgoing = edge.outgoing != :straight
        arc_curve = arc_is_outgoing ? edge.outgoing : edge.incoming
        p_line = arc_is_outgoing ? pts[mod1(i - 1, n_pts)] : pts[mod1(i + 1, n_pts)]

        seg = rounded_corner_segment_line_arc(
            p_line,
            pts[i],
            arc_curve,
            arc_is_outgoing,
            fillet_r
        )
        disc = rounded_corner_line_arc(p_line, pts[i], arc_curve, arc_is_outgoing, fillet_r)

        if isnothing(disc.T_arc)
            @test isnothing(seg)
        else
            @test !isnothing(seg)
            isnothing(seg) && continue

            # Tangent points match
            @test isapprox(seg.T_arc, disc.T_arc, atol=1.0nm)
            # T_line matches first or last discretized point
            @test isapprox(seg.T_line, disc.points[1], atol=1.0nm) ||
                  isapprox(seg.T_line, disc.points[end], atol=1.0nm)

            # Turn endpoints match tangent points
            p0_f = Paths.p0(seg.fillet)
            p1_f = Paths.p1(seg.fillet)
            if arc_is_outgoing
                @test isapprox(p0_f, seg.T_line, atol=1.0nm)
                @test isapprox(p1_f, seg.T_arc, atol=1.0nm)
            else
                @test isapprox(p0_f, seg.T_arc, atol=1.0nm)
                @test isapprox(p1_f, seg.T_line, atol=1.0nm)
            end

            # Fillet radius is correct
            @test seg.fillet.r ≈ fillet_r
        end
    end

    # round_to_curvilinearpolygon (SolidModel pipeline)
    # Verify that styled_loop produces a CurvilinearPolygon with fillet curves
    # at line-arc corners and trimmed original arcs.
    import DeviceLayout.SolidModels: styled_loop
    rounded_cp = styled_loop(cp, Rounded(fillet_r))
    @test rounded_cp isa CurvilinearPolygon

    # Original: 30 points, 10 arcs, 20 line-arc corners, 10 straight-straight corners.
    # Each rounded corner (line-arc or line-line) adds one point and one curve.
    # Expected: 30 + 20 + 10 = 60 points, 10 + 20 + 10 = 40 curves.
    @test length(DeviceLayout.points(rounded_cp)) == 60
    @test length(rounded_cp.curves) == 40
    @test length(rounded_cp.curve_start_idx) == 40

    # All fillet curves should have the requested radius
    for curve in rounded_cp.curves
        if curve.r ≈ fillet_r
            @test abs(curve.α) < 180.0°
        end
    end

    # Discretizing the rounded CurvilinearPolygon should produce a valid polygon
    rounded_from_sm = to_polygons(rounded_cp)
    @test length(DeviceLayout.points(rounded_from_sm)) > 50

    # G1 continuity check on SolidModel-discretized polygon.
    # The bare to_polygons uses 181 fixed points per arc; the max angular step for
    # the largest original arcs (270° sweep) is π·(3/2)/180 ≈ 0.026 rad.
    # Straight-straight fillet arcs are also discretized at 181 pts, so the fillet
    # step dominates only for very small arcs. Use the larger of the two bounds.
    dθ_max_sm = max(dθ_max, 3π / (2 * 180))
    check_g1_continuity(DeviceLayout.points(rounded_from_sm), dθ_max_sm)

    # Renders without error
    @test_nowarn render!(Cell("sm_rounded", nm), let
        cs = CoordinateSystem("smr", nm)
        place!(cs, rounded_cp, GDSMeta())
        cs
    end)

    # Nested line-arc rounding on a semicircle (bump shape).
    # Diameter along x-axis, arc bulging upward. Both corners are line-arc.
    # Round one corner, then both, verifying G1 continuity at each step.
    import DeviceLayout.SolidModels: styled_loop
    semi_arc = Paths.Turn(-π, 3.0μm, p0=Point(0.0μm, 0.0μm), α0=90.0°)
    semi_cp =
        CurvilinearPolygon([Point(0.0μm, 0.0μm), Point(6.0μm, 0.0μm)], [semi_arc], [1])
    r_la = 0.5μm
    v1 = Point(0.0, 0.0)μm
    v2 = Point(6.0, 0.0)μm

    # Round first line-arc corner
    pol1 = styled_loop(semi_cp, Rounded(r_la; p0=[v1]))
    pol1_poly = to_polygons(pol1)
    pol1_pts = points(pol1_poly)
    @test length(pol1_pts) > 2

    # Round both line-arc corners
    pol2 = styled_loop(pol1, Rounded(r_la; p0=[v2]))
    pol2_poly = to_polygons(pol2)
    pol2_pts = points(pol2_poly)
    @test length(pol2_pts) > length(pol1_pts)

    # G1 continuity check on fully rounded result
    dθ_max_la = 2 * sqrt(2 * ustrip(nm, 1.0nm) / ustrip(nm, r_la))
    check_g1_continuity(pol2_pts, dθ_max_la)

    # No output vertex should coincide with the original sharp corners
    for corner in [v1, v2]
        dists = [norm(p - corner) for p in pol2_pts]
        @test minimum(dists) > 0.01μm
    end

    # Renders without error
    @test_nowarn render!(Cell("nested_rounded", nm), let
        cs = CoordinateSystem("nr", nm)
        place!(cs, pol2_poly, GDSMeta())
        cs
    end)

    # Inverse_selection with line-arc corners
    # Rounding with inverse_selection targeting line-arc vertices should only round
    # the straight-straight corners, not the line-arc ones.
    using DeviceLayout.Curvilinear: line_arc_cornerindices
    import DeviceLayout.Polygons: cornerindices

    simple_cp = let
        # Rectangle with a semicircular bump: 6 vertices, 1 arc
        bump_arc = Paths.Turn(-π, 1.0μm, p0=Point(10.0μm, 2.0μm), α0=π)
        CurvilinearPolygon(
            [
                Point(0.0μm, 0.0μm),
                Point(10.0μm, 0.0μm),
                Point(10.0μm, 2.0μm),
                Point(10.0μm, 4.0μm),
                Point(10.0μm, 6.0μm),
                Point(0.0μm, 6.0μm)
            ],
            [bump_arc],
            [3]
        )
    end
    la_pts = simple_cp.p[line_arc_cornerindices(simple_cp)]
    inv_sty = Rounded(0.5μm; p0=la_pts, inverse_selection=true)
    # inverse_selection with line-arc p0: should select all straight-straight corners
    sc = cornerindices(simple_cp, inv_sty)
    @test sort(sc) == sort(cornerindices(simple_cp))
    # and no line-arc corners
    la = line_arc_cornerindices(simple_cp, inv_sty)
    @test isempty(la)

    # The inverse: selecting with those p0 points should select the line-arc corners
    fwd_sty = Rounded(0.5μm; p0=la_pts)
    la_fwd = line_arc_cornerindices(simple_cp, fwd_sty)
    @test sort(la_fwd) == sort(line_arc_cornerindices(simple_cp))
    sc_fwd = cornerindices(simple_cp, fwd_sty)
    @test isempty(sc_fwd)

    # Negative curve_start_idx
    # A negative curve_start_idx means the curve is parameterized in reverse.
    # Construct a simple polygon with a negative index and verify rounding works.
    neg_arc = Paths.Turn(π / 2, 2.0μm, p0=Point(2.0μm, 4.0μm), α0=-π / 2)
    neg_cp = CurvilinearPolygon(
        [
            Point(0.0μm, 0.0μm),
            Point(4.0μm, 0.0μm),
            Point(4.0μm, 2.0μm),   # p1(neg_arc)
            Point(2.0μm, 4.0μm),   # p0(neg_arc)
            Point(0.0μm, 2.0μm)
        ],
        [neg_arc],
        [-3]  # negative: curve between p[3] and p[4], parameterized from p[4] to p[3]
    )
    @test neg_cp.curve_start_idx[1] < 0

    # Plain rendering must work (catches invalid vertex/curve mismatch)
    neg_plain = to_polygons(neg_cp)
    @test length(points(neg_plain)) > 5

    # Rounded rendering
    neg_rounded = to_polygons(neg_cp, Rounded(0.3μm))
    @test length(points(neg_rounded)) > 5

    # Strict G1 continuity check on ALL vertices
    dθ_max_neg = 2 * sqrt(2 * ustrip(nm, 1.0nm) / ustrip(nm, 0.3μm))
    check_g1_continuity(points(neg_rounded), dθ_max_neg)

    # Containment: rounded polygon must stay within the bounding box of the plain polygon
    plain_pts = points(neg_plain)
    rounded_pts = points(neg_rounded)
    plain_xs = [p.x for p in plain_pts]
    plain_ys = [p.y for p in plain_pts]
    bbox_margin = 0.01μm
    for p in rounded_pts
        @test p.x >= minimum(plain_xs) - bbox_margin
        @test p.x <= maximum(plain_xs) + bbox_margin
        @test p.y >= minimum(plain_ys) - bbox_margin
        @test p.y <= maximum(plain_ys) + bbox_margin
    end

    # Equivalence with positive-index version
    pos_cp = CurvilinearPolygon(
        [
            Point(0.0μm, 0.0μm),
            Point(4.0μm, 0.0μm),
            Point(4.0μm, 2.0μm),
            Point(2.0μm, 4.0μm),
            Point(0.0μm, 2.0μm)
        ],
        [reverse(neg_arc)],
        [3]
    )
    pos_rounded = to_polygons(pos_cp, Rounded(0.3μm))
    pos_pts = points(pos_rounded)
    @test length(rounded_pts) == length(pos_pts)
    for i in eachindex(rounded_pts)
        @test isapprox(rounded_pts[i], pos_pts[i]; atol=1.0nm)
    end

    # Relative rounding with line-arc corners (SolidModel path)
    # RelativeRounded uses a fraction of edge length as radius.
    import DeviceLayout.SolidModels: styled_loop, round_to_curvilinearpolygon
    rel_cp = round_to_curvilinearpolygon(cp, 0.05; relative=true)
    @test rel_cp isa CurvilinearPolygon
    # Should have more curves than the original (fillets added)
    @test length(rel_cp.curves) > length(cp.curves)
    # Discretizes without error
    @test length(points(to_polygons(rel_cp))) > 30

    # Relative rounding via to_polygons(CurvilinearPolygon, Rounded) — discretization path
    # RelativeRounded produces a dimensionless radius; to_polygons must convert per-corner.
    rel_rounded = to_polygons(cp, RelativeRounded(0.15))
    @test length(points(rel_rounded)) > 30

    # Relative result should differ from absolute (different radius semantics)
    @test length(points(rel_rounded)) != length(rounded_pts) ||
          !isapprox(points(rel_rounded)[1], rounded_pts[1]; atol=0.1nm)

    # Unitful issue addressed by Unitful.jl PR#845 bypassed
    rect = Rectangle(10.0μm2μm, 10.0μm2μm)
    cr = CurvilinearRegion(CurvilinearPolygon(points(rect)))
    rnd_μm2nm = Rounded(1.0μm2nm)
    poly = only(to_polygons(rnd_μm2nm(cr))) # Runs without error
    @test coordinatetype(poly) == typeof(1.00μm2μm)
    # Test no-holes bypasses difference2d -- point order would be different
    @test poly == to_polygons(cr.exterior, rnd_μm2nm)
    @test only(to_polygons(cr)) == to_polygons(cr.exterior)
end

@testitem "Horseshoe landing pad rounding" setup = [CommonTestSetup] begin
    using LinearAlgebra
    using DeviceLayout.Curvilinear: edge_type_at_vertex

    # Horseshoe-shaped landing pad: two concentric arcs (outer counterclockwise ~270°, inner clockwise ~289°)
    # connected by straight gap segments with a trace extension.
    # This tests large-sweep arcs where the two straight edges at each arc endpoint
    # approach from nearly opposite directions — a geometry not covered by the
    # rectangle-with-features test above.

    R = 340.0μm        # outer radius
    gap = 100.0μm      # gap between arcs
    trace = 280.0μm    # trace width at opening
    trace_height = 100.0μm  # trace extension length

    total = trace + 2gap
    θ = asin(total / (2R))

    outer_start = Point(R * cos(θ), R * sin(θ))
    outer_end = Point(R * cos(θ), -R * sin(θ))
    x1 = Point(R * cos(θ) + trace_height, -R * sin(θ))
    x2 = Point(x1.x, x1.y + gap)

    r_inner = R - gap
    ϕ = asin(-x2.y / r_inner)
    inner_start = Point(r_inner * cos(ϕ), -r_inner * sin(ϕ))
    inner_end = Point(r_inner * cos(ϕ), r_inner * sin(ϕ))
    x3 = Point(x2.x, -x2.y)
    x4 = Point(x1.x, -x1.y)

    # Outer arc: counterclockwise from outer_start to outer_end
    outer_α = 2π - 2θ
    outer_α0 = atan(outer_start.y, outer_start.x) + π / 2
    outer_arc = Paths.Turn(outer_α, R, p0=outer_start, α0=outer_α0)

    # Inner arc: clockwise from inner_start to inner_end
    inner_α = -(2π - 2ϕ)
    inner_α0 = atan(inner_start.y, inner_start.x) - π / 2
    inner_arc = Paths.Turn(inner_α, r_inner, p0=inner_start, α0=inner_α0)

    # Verify arc endpoints
    @test isapprox(Paths.p1(outer_arc), outer_end, atol=0.1nm)
    @test isapprox(Paths.p1(inner_arc), inner_end, atol=0.1nm)

    pts = [outer_start, outer_end, x1, x2, inner_start, inner_end, x3, x4]
    horseshoe = CurvilinearPolygon(pts, [outer_arc, inner_arc], [1, 5])

    # Edge type verification
    @test edge_type_at_vertex(horseshoe, 1).outgoing == outer_arc  # LINE→ARC
    @test edge_type_at_vertex(horseshoe, 2).incoming == outer_arc  # ARC→LINE
    @test edge_type_at_vertex(horseshoe, 5).outgoing == inner_arc  # LINE→ARC
    @test edge_type_at_vertex(horseshoe, 6).incoming == inner_arc  # ARC→LINE
    for i in [3, 4, 7, 8]
        @test edge_type_at_vertex(horseshoe, i).incoming == :straight
        @test edge_type_at_vertex(horseshoe, i).outgoing == :straight
    end

    # Renders without rounding
    @test_nowarn render!(
        Cell("horseshoe_no_round", nm),
        let
            cs = CoordinateSystem("hnr", nm)
            place!(cs, horseshoe, GDSMeta())
            cs
        end
    )

    # Apply rounding — all 8 corners should be rounded
    fillet_r = 30.0μm
    rounded = to_polygons(horseshoe, Rounded(fillet_r))
    rounded_pts = points(rounded)
    @test length(rounded_pts) > 8  # must have more vertices than the 8 original

    # G1 continuity check on horseshoe rounding.
    # dθ_max accounts for both the fillet discretization step and the 181-point
    # fixed discretization of large original arcs (up to ~270° sweep).
    dθ_max = max(
        2 * sqrt(2 * ustrip(nm, 1.0nm) / ustrip(nm, fillet_r)),
        2π / 180  # upper bound from 181-point arc discretization
    )
    check_g1_continuity(rounded_pts, dθ_max)

    # Verify rounding at ALL 8 original vertices: no output vertex should coincide
    # with any original corner. If rounding worked, every corner is replaced by a
    # fillet arc and the original sharp point is gone.
    labels =
        ["outer_start", "outer_end", "x1", "x2", "inner_start", "inner_end", "x3", "x4"]
    original_pts = [outer_start, outer_end, x1, x2, inner_start, inner_end, x3, x4]
    for (vi, orig_pt) in enumerate(original_pts)
        dists = [norm(p - orig_pt) for p in rounded_pts]
        d = minimum(dists)
        d <= 0.1μm && @info "Vertex $vi ($(labels[vi])) NOT rounded: min_dist=$d"
        @test d > 0.1μm
    end

    # Renders after rounding
    @test_nowarn render!(Cell("horseshoe_rounded", nm), let
        cs = CoordinateSystem("hr", nm)
        place!(cs, rounded, GDSMeta())
        cs
    end)

    # SolidModel segment version on horseshoe geometry (large-sweep arcs)
    import DeviceLayout.SolidModels: rounded_corner_segment_line_arc
    using DeviceLayout.Curvilinear: rounded_corner_line_arc

    horseshoe_fillet_r = 20.0μm
    horseshoe_pts_list = [outer_start, outer_end, x1, x2, inner_start, inner_end, x3, x4]
    n_horse = length(horseshoe_pts_list)
    for i = 1:n_horse
        edge = edge_type_at_vertex(horseshoe, i)
        is_line_arc = (edge.incoming == :straight) != (edge.outgoing == :straight)
        !is_line_arc && continue

        arc_is_outgoing = edge.outgoing != :straight
        arc_curve = arc_is_outgoing ? edge.outgoing : edge.incoming
        p_line =
            arc_is_outgoing ? horseshoe_pts_list[mod1(i - 1, n_horse)] :
            horseshoe_pts_list[mod1(i + 1, n_horse)]

        seg = rounded_corner_segment_line_arc(
            p_line,
            horseshoe_pts_list[i],
            arc_curve,
            arc_is_outgoing,
            horseshoe_fillet_r
        )
        disc = rounded_corner_line_arc(
            p_line,
            horseshoe_pts_list[i],
            arc_curve,
            arc_is_outgoing,
            horseshoe_fillet_r
        )

        if isnothing(disc.T_arc)
            @test isnothing(seg)
        else
            @test !isnothing(seg)
            isnothing(seg) && continue
            @test isapprox(seg.T_arc, disc.T_arc, atol=1.0nm)
            # T_line matches first or last discretized point
            @test isapprox(seg.T_line, disc.points[1], atol=1.0nm) ||
                  isapprox(seg.T_line, disc.points[end], atol=1.0nm)

            # Turn endpoints match tangent points
            p0_f = Paths.p0(seg.fillet)
            p1_f = Paths.p1(seg.fillet)
            if arc_is_outgoing
                @test isapprox(p0_f, seg.T_line, atol=1.0nm)
                @test isapprox(p1_f, seg.T_arc, atol=1.0nm)
            else
                @test isapprox(p0_f, seg.T_arc, atol=1.0nm)
                @test isapprox(p1_f, seg.T_line, atol=1.0nm)
            end

            @test seg.fillet.r ≈ horseshoe_fillet_r
        end
    end

    # SolidModel styled_loop test for horseshoe
    import DeviceLayout.SolidModels: styled_loop
    horseshoe_sm = styled_loop(horseshoe, Rounded(horseshoe_fillet_r))
    @test horseshoe_sm isa CurvilinearPolygon
    @test length(horseshoe_sm.curves) > length(horseshoe.curves)
end
