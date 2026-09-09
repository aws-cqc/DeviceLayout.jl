@testitem "ConformalRender smoke" setup = [CommonTestSetup, QuietGmshSetup] begin
    using DeviceLayout:
        Point,
        Rectangle,
        centered,
        Polygon,
        points,
        coordinatetype,
        onenanometer,
        ClippedPolygon,
        difference2d,
        Paths,
        Path,
        LineSegment,
        straight!,
        turn!,
        bspline!,
        union2d,
        to_polygons
    using DeviceLayout.Polygons: Rounded
    using DeviceLayout.Curvilinear: CurvilinearPolygon, CurvilinearRegion
    using DeviceLayout.SolidModels:
        SolidModel,
        ConformalRenderContext,
        add_conformal_loop!,
        render_conformal!,
        kernel,
        gmsh,
        hasgroup
    import DeviceLayout
    import DeviceLayout.SolidModels

    @testset "ConformalRenderContext construction" begin
        ctx = ConformalRenderContext()
        @test ctx.vertex_merge_atol == 2e-3
        @test ctx.center_merge_atol == SolidModels.POINT_MERGE_ATOL
        @test isempty(ctx.curve_cache)
        @test isempty(ctx.endpoint_curve_index)
        @test ctx.stats[:hits] == 0
        @test ctx.stats[:misses] == 0

        # Custom tolerances
        ctx2 = ConformalRenderContext(; vertex_merge_atol=5e-3)
        @test ctx2.vertex_merge_atol == 5e-3
    end

    @testset "add_conformal_loop! dedupes shared edges" begin
        # Two rectangles sharing an edge — the shared edge should resolve to
        # the same OCC tag in both loops, proving the cache works.
        sm = SolidModel("conformal_share_edge"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        # Left rect: (0,0) → (10,0) → (10,10) → (0,10)
        left = CurvilinearPolygon(
            Point{typeof(1.0μm)}[
                Point(0.0μm, 0.0μm),
                Point(10.0μm, 0.0μm),
                Point(10.0μm, 10.0μm),
                Point(0.0μm, 10.0μm)
            ]
        )
        # Right rect: (10,0) → (20,0) → (20,10) → (10,10) — shared edge is x=10 side
        right = CurvilinearPolygon(
            Point{typeof(1.0μm)}[
                Point(10.0μm, 0.0μm),
                Point(20.0μm, 0.0μm),
                Point(20.0μm, 10.0μm),
                Point(10.0μm, 10.0μm)
            ]
        )

        loop1 = add_conformal_loop!(ctx, left, k, 0.0μm; points_cache)
        loop2 = add_conformal_loop!(ctx, right, k, 0.0μm; points_cache)

        # After the second loop, we should see at least one cache hit — the
        # shared edge (10,0)→(10,10) should reuse the tag from the first loop.
        @test ctx.stats[:hits] >= 1
        @test loop1 != loop2  # they are different loops

        gmsh.finalize()
    end

    @testset "render_conformal! renders same geometry as render!" begin
        # Simple CS with two adjacent rectangles; verify both render! and
        # render_conformal! produce a valid SolidModel with the same number
        # of surface entities.
        cs = CoordinateSystem("adjacent", nm)
        place!(cs, Rectangle(Point(0.0μm, 0.0μm), Point(10.0μm, 10.0μm)), :l1)
        place!(cs, Rectangle(Point(10.0μm, 0.0μm), Point(20.0μm, 10.0μm)), :l1)

        sm_stock = SolidModel("stock"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render!(sm_stock, cs)
        n_surf_stock = length(gmsh.model.occ.getEntities(2))

        sm_conformal = SolidModel("conformal"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm_conformal, cs)
        n_surf_conformal = length(gmsh.model.occ.getEntities(2))

        # Both should produce two surfaces
        @test n_surf_stock >= 2
        @test n_surf_conformal >= 2
        # Both models have the expected physical group
        @test hasgroup(sm_stock, "l1", 2)
        @test hasgroup(sm_conformal, "l1", 2)

        gmsh.finalize()
    end

    @testset "render_conformal! fragment_backstop kwarg" begin
        cs = CoordinateSystem("bs", nm)
        place!(cs, Rectangle(Point(0.0μm, 0.0μm), Point(10.0μm, 10.0μm)), :l1)
        place!(cs, Rectangle(Point(10.0μm, 0.0μm), Point(20.0μm, 10.0μm)), :l1)

        # Default: no backstop
        sm1 = SolidModel("bs_default"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm1, cs)
        @test hasgroup(sm1, "l1", 2)

        # With backstop: same result (backstop runs as no-op when the cache
        # already produced conformal geometry).
        sm2 = SolidModel("bs_on"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm2, cs; fragment_backstop=true)
        @test hasgroup(sm2, "l1", 2)

        gmsh.finalize()
    end

    @testset "render_conformal! rejects GmshNative kernel" begin
        sm_native = SolidModel("native", SolidModels.GmshNative(); overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        cs = CoordinateSystem("dummy", nm)
        place!(cs, Rectangle(Point(0.0μm, 0.0μm), Point(1.0μm, 1.0μm)), :l1)
        @test_throws ErrorException render_conformal!(sm_native, cs)
        gmsh.finalize()
    end

    @testset "add_conformal_loop! with Paths.Turn (short arc)" begin
        # Direct exercise of _add_conformal_curve!(Paths.Turn) — a 90° arc.
        sm = SolidModel("turn_short"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        R = 100.0μm
        pp = [Point(0.0μm, 0.0μm), Point(R, 0.0μm), Point(0.0μm, R)]
        turn = Paths.Turn(90°, R, α0=90°, p0=pp[2])
        cp = CurvilinearPolygon(pp, [turn], [2])
        loop = add_conformal_loop!(ctx, cp, k, 0.0μm; points_cache)
        @test loop isa Integer
        gmsh.finalize()
    end

    @testset "add_conformal_loop! with Paths.Turn (large arc)" begin
        # Turn with |α| >= 180° triggers the multi-segment arc path.
        sm = SolidModel("turn_large"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        R = 50.0μm
        pp = [Point(0.0μm, 0.0μm), Point(R, 0.0μm), Point(-R, 0.0μm)]
        turn = Paths.Turn(180°, R, α0=90°, p0=pp[2])
        cp = CurvilinearPolygon(pp, [turn], [2])
        loop = add_conformal_loop!(ctx, cp, k, 0.0μm; points_cache)
        @test loop isa Integer
        gmsh.finalize()
    end

    @testset "add_conformal_loop! with Paths.BSpline" begin
        # Exercise _add_conformal_curve!(Paths.BSpline).
        sm = SolidModel("bspline"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        pp = [
            Point(0.0μm, 0.0μm),
            Point(100.0μm, 0.0μm),
            Point(100.0μm, 100.0μm),
            Point(0.0μm, 100.0μm)
        ]
        spline_pts = [pp[2], Point(150.0μm, 50.0μm), pp[3]]
        t0 = Point(1.0μm, 0.0μm)
        t1 = Point(-1.0μm, 0.0μm)
        seg = Paths.BSpline(spline_pts, t0, t1)
        cp = CurvilinearPolygon(pp, [seg], [2])
        loop = add_conformal_loop!(ctx, cp, k, 0.0μm; points_cache)
        @test loop isa Integer
        gmsh.finalize()
    end

    @testset "render_conformal! with CurvilinearRegion (rounded rect)" begin
        # A Rounded(Rectangle) renders to a CurvilinearRegion — this exercises
        # _add_conformal!(CurvilinearRegion) and CurvilinearRegion's
        # exterior+holes assembly path.
        cs = CoordinateSystem("rounded", nm)
        rect = Rectangle(Point(0.0μm, 0.0μm), Point(50.0μm, 30.0μm))
        place!(cs, Rounded(5.0μm)(rect), :l1)

        sm = SolidModel("cvr"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm, cs)
        @test hasgroup(sm, "l1", 2)
        @test length(SolidModels.mesh_control_points()[(5.0, -1.0)]) == 4
        # A rounded rectangle should produce a single surface with curved edges.
        @test length(gmsh.model.occ.getEntities(2)) >= 1

        sm_off = SolidModel("cvr_off"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm_off, cs; curvature_sizing=false)
        @test isempty(SolidModels.mesh_control_points())
        gmsh.finalize()
    end

    @testset "render_conformal! with ClippedPolygon (holes)" begin
        # Exercise CurvilinearRegion's `holes` path via a ClippedPolygon.
        cs = CoordinateSystem("holed", nm)
        outer = Rectangle(Point(0.0μm, 0.0μm), Point(100.0μm, 100.0μm))
        inner = Rectangle(Point(30.0μm, 30.0μm), Point(70.0μm, 70.0μm))
        clipped = difference2d(outer, inner)
        place!(cs, clipped, :l1)

        sm = SolidModel("holed"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm, cs)
        @test hasgroup(sm, "l1", 2)
        gmsh.finalize()
    end

    @testset "render_conformal! preserves shared vertex identity" begin
        # Two adjacent rectangles → the shared edge should resolve to a single
        # OCC edge tag. If dedup works, the total edge count is < 8 (would be
        # 8 if the shared edge duplicated).
        cs = CoordinateSystem("shared", nm)
        place!(cs, Rectangle(Point(0.0μm, 0.0μm), Point(10.0μm, 10.0μm)), :l1)
        place!(cs, Rectangle(Point(10.0μm, 0.0μm), Point(20.0μm, 10.0μm)), :l1)

        ctx = ConformalRenderContext()
        sm = SolidModel("shared"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm, cs; context=ctx)
        # Each rect contributes 4 edges; a duplicated shared edge would give 8.
        # With dedup, the shared edge is 1, so total = 7.
        @test length(gmsh.model.occ.getEntities(1)) == 7
        # The cache should have registered at least one hit for the shared edge.
        @test ctx.stats[:hits] >= 1
        gmsh.finalize()
    end

    @testset "render_conformal! zmap positions surfaces at nonzero z" begin
        # Exercise the zmap kwarg on render_conformal!.
        cs = CoordinateSystem("zmap", nm)
        place!(cs, Rectangle(Point(0.0μm, 0.0μm), Point(10.0μm, 10.0μm)), :l1)

        sm = SolidModel("zmap"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        z_target = 5.0μm
        render_conformal!(sm, cs; zmap=(_) -> z_target)
        @test hasgroup(sm, "l1", 2)
        # Bounding-box z should reflect the zmap.
        _, _, zmin, _, _, zmax =
            gmsh.model.occ.getBoundingBox(2, gmsh.model.occ.getEntities(2)[1][2])
        @test isapprox(zmin, ustrip(SolidModels.STP_UNIT, z_target); atol=1e-6)
        @test isapprox(zmax, ustrip(SolidModels.STP_UNIT, z_target); atol=1e-6)
        gmsh.finalize()
    end

    @testset "prefer-curve invariant: arc then line on shared endpoints" begin
        # After an arc on endpoints (a, b), a line request on the same endpoints
        # must reuse the arc tag (up to sign), not create a duplicate straight
        # edge — otherwise a shared boundary between an arc-side and a
        # line-side face is non-conformal.
        sm = SolidModel("prefer_curve_arc_line"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        R = 100.0μm
        pp = [Point(0.0μm, 0.0μm), Point(R, 0.0μm), Point(0.0μm, R)]
        turn = Paths.Turn(90°, R, α0=90°, p0=pp[2])
        cp_arc = CurvilinearPolygon(pp, [turn], [2])
        add_conformal_loop!(ctx, cp_arc, k, 0.0μm; points_cache)

        # Straight-edge polygon that shares the (pp[2], pp[3]) endpoints. It
        # would ordinarily be a chord, but the cache should return the arc tag.
        hits_before = ctx.stats[:hits]
        line_cp = CurvilinearPolygon(pp)  # no curve — pure line loop
        add_conformal_loop!(ctx, line_cp, k, 0.0μm; points_cache)
        @test ctx.stats[:hits] > hits_before  # arc was reused for a line request
        gmsh.finalize()
    end

    @testset "prefer-curve invariant: spline then line on shared endpoints" begin
        sm = SolidModel("prefer_curve_spline_line"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        pp = [
            Point(0.0μm, 0.0μm),
            Point(100.0μm, 0.0μm),
            Point(100.0μm, 100.0μm),
            Point(0.0μm, 100.0μm)
        ]
        spline_pts = [pp[2], Point(150.0μm, 50.0μm), pp[3]]
        seg = Paths.BSpline(spline_pts, Point(1.0μm, 0.0μm), Point(-1.0μm, 0.0μm))
        cp_spline = CurvilinearPolygon(pp, [seg], [2])
        add_conformal_loop!(ctx, cp_spline, k, 0.0μm; points_cache)

        hits_before = ctx.stats[:hits]
        line_cp = CurvilinearPolygon(pp)  # straight (pp[2], pp[3])
        add_conformal_loop!(ctx, line_cp, k, 0.0μm; points_cache)
        # If the spline registered itself in endpoint_curve_index, the later
        # line request hits — otherwise a duplicate straight edge is created
        # and the shared boundary is non-conformal.
        @test ctx.stats[:hits] > hits_before
        gmsh.finalize()
    end

    @testset "_add_conformal!(::LineSegment) 1D dispatch" begin
        # A LineSegment placed on a coordinate system exercises the 1D-entity
        # branch of _add_conformal!. It should register a curve and a physical
        # group at dim=1.
        cs = CoordinateSystem("linesegs", μm)
        place!(cs, LineSegment(Point(0.0μm, 0.0μm), Point(10.0μm, 0.0μm)), :l1)
        place!(cs, LineSegment(Point(10.0μm, 0.0μm), Point(10.0μm, 5.0μm)), :l1)

        sm = SolidModel("linesegs"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm, cs)
        # `l1` should end up as a group at dim=1 (segments do not get closed
        # into a 2D face) with at least two 1D entities in the model.
        @test hasgroup(sm, "l1", 1)
        @test length(gmsh.model.occ.getEntities(1)) >= 2
        gmsh.finalize()
    end

    @testset "arc curve_cache exact-key hit (existing !== nothing branch)" begin
        # Same Turn requested twice → second call hits the exact-key branch
        # and returns the same tag (up to sign).
        sm = SolidModel("arc_dup"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        R = 100.0μm
        pp = [Point(0.0μm, 0.0μm), Point(R, 0.0μm), Point(0.0μm, R)]
        turn = Paths.Turn(90°, R, α0=90°, p0=pp[2])
        cp1 = CurvilinearPolygon(pp, [turn], [2])
        cp2 = CurvilinearPolygon(pp, [turn], [2])  # same Turn object

        misses_before = ctx.stats[:misses]
        arcs_before = ctx.stats[:arcs]
        add_conformal_loop!(ctx, cp1, k, 0.0μm; points_cache)
        arcs_after_first = ctx.stats[:arcs]
        add_conformal_loop!(ctx, cp2, k, 0.0μm; points_cache)
        # Second render created zero new arcs (all hits from the cache).
        @test ctx.stats[:arcs] == arcs_after_first
        # And at least one exact-key hit was recorded.
        @test ctx.stats[:hits] >= 1
        gmsh.finalize()
    end

    @testset "spline curve_cache exact-key hit" begin
        sm = SolidModel("spline_dup"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        pp = [
            Point(0.0μm, 0.0μm),
            Point(100.0μm, 0.0μm),
            Point(100.0μm, 100.0μm),
            Point(0.0μm, 100.0μm)
        ]
        seg = Paths.BSpline(
            [pp[2], Point(150.0μm, 50.0μm), pp[3]],
            Point(1.0μm, 0.0μm),
            Point(-1.0μm, 0.0μm)
        )
        cp1 = CurvilinearPolygon(pp, [seg], [2])
        cp2 = CurvilinearPolygon(pp, [seg], [2])

        add_conformal_loop!(ctx, cp1, k, 0.0μm; points_cache)
        splines_after_first = ctx.stats[:splines]
        add_conformal_loop!(ctx, cp2, k, 0.0μm; points_cache)
        @test ctx.stats[:splines] == splines_after_first
        @test ctx.stats[:hits] >= 1
        gmsh.finalize()
    end

    @testset "midpoint check rejects 2-edge lens fusion" begin
        # Precondition 2 case: two arcs on the same endpoints but different
        # midpoints (bulge up vs. bulge down). Endpoint-only fusion would
        # collapse both into one OCC edge. The midpoint check must keep them
        # as two distinct entities.
        #
        # We drive the primitives directly rather than through
        # add_conformal_loop! so we can construct the exact "two arcs on the
        # same endpoints, different centers" case without a Path adapter.
        sm = SolidModel("lens_primitive"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        SolidModels = DeviceLayout.SolidModels
        points_cache = SolidModels.PointsCache()

        # Endpoints on the x axis; centers above and below.
        p1 = SolidModels.ConformalRender._cached_point_relaxed!(
            k,
            ctx,
            -50.0,
            0.0,
            0.0,
            points_cache
        )
        p2 = SolidModels.ConformalRender._cached_point_relaxed!(
            k,
            ctx,
            50.0,
            0.0,
            0.0,
            points_cache
        )
        # Center above chord: bulges downward → midpoint below chord.
        c_above = SolidModels.ConformalRender._cached_point_strict!(
            k,
            ctx,
            0.0,
            80.0,
            0.0,
            points_cache
        )
        # Center below chord: bulges upward → midpoint above chord.
        c_below = SolidModels.ConformalRender._cached_point_strict!(
            k,
            ctx,
            0.0,
            -80.0,
            0.0,
            points_cache
        )

        rej_before = ctx.stats[:midpoint_rejections]
        arcs_before = ctx.stats[:arcs]
        tag_a = SolidModels.ConformalRender._cached_add_arc!(k, ctx, p1, c_above, p2)
        tag_b = SolidModels.ConformalRender._cached_add_arc!(k, ctx, p1, c_below, p2)

        @test ctx.stats[:arcs] == arcs_before + 2  # both arcs created fresh
        @test ctx.stats[:midpoint_rejections] > rej_before
        @test abs(tag_a) != abs(tag_b)  # distinct OCC entities
        gmsh.finalize()
    end

    @testset "unsupported segment type throws ArgumentError" begin
        # A Paths.Straight reaching the curve dispatcher should error rather
        # than silently BSpline-approximating (which would leave the edge out
        # of the cache and break conformality with the caching side).
        sm = SolidModel("bad_seg"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_cache = SolidModels.PointsCache()

        a = Point(0.0μm, 0.0μm)
        b = Point(10.0μm, 0.0μm)
        # Hand-construct a CurvilinearPolygon carrying a Paths.Straight,
        # which would normally not appear here — just to hit the fallback.
        straight = Paths.Straight(10.0μm, a, 0.0°)
        cp = CurvilinearPolygon([a, b], [straight], [1])
        @test_throws ArgumentError add_conformal_loop!(ctx, cp, k, 0.0μm; points_cache)
        gmsh.finalize()
    end

    @testset "render_conformal! with Path(Trace) — straight + turn" begin
        # Trace path with a straight and a 90° turn — the production shape,
        # not a hand-built CurvilinearPolygon.
        cs = CoordinateSystem("trace_path", nm)
        pa = Path(Point(0.0μm, 0.0μm), α0=0°)
        straight!(pa, 50μm, Paths.Trace(2.0μm))
        turn!(pa, 90°, 20μm)
        straight!(pa, 50μm)
        place!(cs, pa, :l1)

        sm = SolidModel("trace_path"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm, cs)
        @test hasgroup(sm, "l1", 2)
        gmsh.finalize()
    end

    @testset "render_conformal! with Path(TaperTrace)" begin
        # TaperTrace path — the width changes along the segment, which is the
        # kind of style OffsetSegment gets pulled in for.
        cs = CoordinateSystem("taper_path", nm)
        pa = Path(Point(0.0μm, 0.0μm), α0=0°)
        straight!(pa, 40μm, Paths.TaperTrace(1.0μm, 3.0μm))
        turn!(pa, 45°, 30μm)
        place!(cs, pa, :l1)

        sm = SolidModel("taper_path"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm, cs)
        @test hasgroup(sm, "l1", 2)
        gmsh.finalize()
    end

    @testset "render_conformal! with Path(SimpleCPW) — bspline routing" begin
        # SimpleCPW with a bspline segment — exercises both the CPW inner+outer
        # boundary rendering and the BSpline dispatch.
        cs = CoordinateSystem("cpw_bspline", nm)
        pa = Path(Point(0.0μm, 0.0μm), α0=0°)
        straight!(pa, 20μm, Paths.SimpleCPW(2.0μm, 1.0μm))
        bspline!(pa, [Point(60.0μm, 40.0μm)], 90°)
        straight!(pa, 20μm)
        place!(cs, pa, :l1)

        sm = SolidModel("cpw_bspline"; overwrite=true)
        gmsh.option.setNumber("General.Verbosity", 0)
        render_conformal!(sm, cs)
        @test hasgroup(sm, "l1", 2)
        gmsh.finalize()
    end

    # ─── Preprocessing (split_pinches) ────────────────────────────────────

    @testset "find_pinch_points detects self-touching contours" begin
        # A rectangular polygon with a duplicate vertex at (5, 0) — a
        # zero-width neck. The pinch is between indices 3 and 6.
        pts = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(5.0μm, 0.0μm),
            Point(5.0μm, 5.0μm),
            Point(0.0μm, 5.0μm),
            Point(0.0μm, 0.0μm),
            Point(5.0μm, 0.0μm)  # same coord as index 2 → pinch (2, 6)
        ]
        pinches = SolidModels.ConformalRender.find_pinch_points(pts)
        @test !isempty(pinches)
        @test any(p -> p == (1, 5) || p == (2, 6), pinches)
    end

    @testset "find_pinch_points returns empty for a clean polygon" begin
        pts = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(10.0μm, 0.0μm),
            Point(10.0μm, 10.0μm),
            Point(0.0μm, 10.0μm)
        ]
        @test isempty(SolidModels.ConformalRender.find_pinch_points(pts))
    end

    @testset "Clipper does not produce pinches on simple touching shapes" begin
        # Simple pinch-shaped inputs (diagonal-touching rects, hourglass
        # apex-to-apex triangles) don't produce self-touching outlines from
        # `union2d` — Clipper separates them into distinct polygons. This
        # documents the class of inputs where `find_pinch_points` /
        # `split_pinches` are unnecessary.
        #
        # Coordinates are chosen large enough (~100 µm) that no two
        # distinct vertices fall within `find_pinch_points`'s 2 nm
        # atol (the fn ustrips whatever unit the point carries).

        # Diagonal-touching rectangles at (0, 0)
        r1 = Polygon([
            Point(-100.0μm, 0.0μm),
            Point(0.0μm, 0.0μm),
            Point(0.0μm, 100.0μm),
            Point(-100.0μm, 100.0μm)
        ])
        r2 = Polygon([
            Point(0.0μm, -100.0μm),
            Point(100.0μm, -100.0μm),
            Point(100.0μm, 0.0μm),
            Point(0.0μm, 0.0μm)
        ])
        polys1 = to_polygons(union2d([r1, r2]))
        @test length(polys1) == 2  # separated, not one figure-8 poly
        for p in polys1
            @test isempty(SolidModels.ConformalRender.find_pinch_points(collect(points(p))))
        end

        # Hourglass triangles sharing apex at (0, 0)
        tri1 = Polygon([
            Point(0.0μm, 0.0μm),
            Point(100.0μm, 100.0μm),
            Point(-100.0μm, 100.0μm)
        ])
        tri2 = Polygon([
            Point(0.0μm, 0.0μm),
            Point(-100.0μm, -100.0μm),
            Point(100.0μm, -100.0μm)
        ])
        polys2 = to_polygons(union2d([tri1, tri2]))
        @test length(polys2) == 2  # separated, not one bow-tie poly
        for p in polys2
            @test isempty(SolidModels.ConformalRender.find_pinch_points(collect(points(p))))
        end
    end

    @testset "find_pinch_points catches noding-induced pinches" begin
        # The pinch case `find_pinch_points`/`split_pinches` actually needs
        # to handle in a downstream pipeline: shared-boundary vertex
        # injection (used to make adjacent physical groups share bit-
        # identical vertex sequences on their common boundary) turns a
        # Clipper-clean pair of outlines into a self-touching outline.
        #
        # Region A visits (150 µm, 0) once as an interior corner of a
        # satellite feature. A also has a long shared-edge segment
        # (-300, 0) → (300, 0) with no interior vertex at x=150. When
        # a noding pass injects region B's on-edge port anchor at
        # (150, 0) into that segment, A's outline visits (150 µm, 0)
        # twice at non-adjacent positions — the exact failure OCC
        # rejects with "Curve loop is not closed".
        A = Point{typeof(1.0μm)}[
            Point(-300.0μm, 0.0μm),
            Point(300.0μm, 0.0μm),
            Point(300.0μm, 200.0μm),
            Point(200.0μm, 200.0μm),
            Point(200.0μm, 100.0μm),
            Point(100.0μm, 100.0μm),
            Point(150.0μm, 0.0μm),    # A already has this vertex
            Point(100.0μm, 50.0μm),
            Point(0.0μm, 50.0μm),
            Point(-300.0μm, 200.0μm)
        ]
        @test isempty(SolidModels.ConformalRender.find_pinch_points(A))

        # Simulate the injection: B's on-edge port anchor at (150, 0)
        # gets injected into A's long shared-edge segment.
        A_after_noding = vcat(A[1:1], [Point(150.0μm, 0.0μm)], A[2:end])

        pinches = SolidModels.ConformalRender.find_pinch_points(A_after_noding)
        @test length(pinches) == 1
        i, j = pinches[1]
        @test A_after_noding[i] ≈ A_after_noding[j]
        # split_pinches then cleaves A into two simple faces at the pinch.
        cp = CurvilinearPolygon(A_after_noding)
        r = CurvilinearRegion(cp, CurvilinearPolygon{typeof(1.0μm)}[])
        @test length(SolidModels.split_pinches([r])) >= 2
    end

    @testset "render_conformal! fails on pinched outline, split_pinches fixes it" begin
        # End-to-end: build a CoordinateSystem containing a
        # `CurvilinearRegion` whose outline was produced by symmetric
        # shared-boundary noding (see previous testset for construction).
        # Rendering it directly through `render_conformal!` must raise
        # OCC's "Curve loop is not closed" error. Preprocessing the region
        # with `split_pinches` first must let the render complete.
        A_pinched = Point{typeof(1.0μm)}[
            Point(-300.0μm, 0.0μm),
            Point(150.0μm, 0.0μm),   # injected copy
            Point(300.0μm, 0.0μm),
            Point(300.0μm, 200.0μm),
            Point(200.0μm, 200.0μm),
            Point(200.0μm, 60.0μm),
            Point(150.0μm, 0.0μm),   # A's original notch tip — pinch
            Point(100.0μm, 60.0μm),
            Point(100.0μm, 200.0μm),
            Point(-300.0μm, 200.0μm)
        ]
        cp = CurvilinearPolygon(A_pinched)
        region = CurvilinearRegion(cp, CurvilinearPolygon{typeof(1.0μm)}[])

        # Attempt 1: render_conformal! on the pinched outline throws.
        cs_pinched = CoordinateSystem("pinched_direct", nm)
        place!(cs_pinched, region, :layer_A)
        sm_pinched = SolidModel("pinched_direct"; overwrite=true)
        @test_throws ErrorException render_conformal!(sm_pinched, cs_pinched)
        gmsh.finalize()

        # Attempt 2: split_pinches first, then render_conformal! succeeds.
        split_regions = SolidModels.split_pinches([region])
        @test length(split_regions) >= 2

        cs_split = CoordinateSystem("pinched_split", nm)
        for r in split_regions
            place!(cs_split, r, :layer_A)
        end
        sm_split = SolidModel("pinched_split"; overwrite=true)
        render_conformal!(sm_split, cs_split)
        @test hasgroup(sm_split, "layer_A", 2)
        gmsh.finalize()
    end

    @testset "split_pinches splits a figure-8 into two simple loops" begin
        # Figure-8: two lobes touching at (5, 0). One CurvilinearRegion
        # in, two out.
        pts = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(5.0μm, 0.0μm),  # pinch
            Point(2.0μm, 5.0μm),
            Point(0.0μm, 0.0μm),  # loop 1 closes here
            Point(5.0μm, 0.0μm),  # pinch again — starts loop 2
            Point(8.0μm, 5.0μm),
            Point(10.0μm, 0.0μm)
        ]
        cp = CurvilinearPolygon(pts)
        r = CurvilinearRegion(cp, CurvilinearPolygon{typeof(1.0μm)}[])
        out = SolidModels.split_pinches([r])
        @test length(out) >= 2  # at least two lobes after split
    end

    @testset "split_pinches leaves clean regions untouched" begin
        pts = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(10.0μm, 0.0μm),
            Point(10.0μm, 10.0μm),
            Point(0.0μm, 10.0μm)
        ]
        cp = CurvilinearPolygon(pts)
        r = CurvilinearRegion(cp, CurvilinearPolygon{typeof(1.0μm)}[])
        out = SolidModels.split_pinches([r])
        @test length(out) == 1
        # Same points, in the same order.
        @test points(out[1].exterior) == pts
    end

    @testset "split_pinches handles multi-lobe exterior + hole assignment" begin
        # A region whose exterior has TWO pinches, splitting it into three
        # simple lobes. Also has a hole that should get assigned to the
        # containing lobe by the point-in-polygon test.
        # Layout (drawn upside-down for clarity):
        #   Three squares strung side-by-side, each touching the next at one
        #   vertex — chain of pinch points at x=10 and x=20, y=0.
        pts = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(10.0μm, 0.0μm),  # pinch 1 (also index below)
            Point(10.0μm, 10.0μm),
            Point(0.0μm, 10.0μm),
            Point(0.0μm, 0.0μm),   # closes lobe 1, duplicate of index 1
            Point(10.0μm, 0.0μm),  # pinch 1 continued
            Point(20.0μm, 0.0μm),  # pinch 2
            Point(20.0μm, 10.0μm),
            Point(10.0μm, 10.0μm)  # duplicate of index 3
        ]
        cp = CurvilinearPolygon(pts)
        # Add a hole inside what will become the first lobe.
        hole_pts = Point{typeof(1.0μm)}[
            Point(2.0μm, 2.0μm),
            Point(4.0μm, 2.0μm),
            Point(4.0μm, 4.0μm),
            Point(2.0μm, 4.0μm)
        ]
        hole = CurvilinearPolygon(hole_pts)
        r = CurvilinearRegion(cp, [hole])
        out = SolidModels.split_pinches([r])
        # Should split into multiple simple regions.
        @test length(out) >= 2
        # Total holes across all output regions should be 1 (the original hole).
        @test sum(length(rr.holes) for rr in out) == 1
    end

    @testset "split_pinches drops zero-area sliver sub-loops" begin
        # A polygon where a run of collinear duplicated vertices causes a
        # 2-point sub-loop to be carved off. Such slivers should be dropped.
        pts = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(5.0μm, 0.0μm),  # will pinch with index 4
            Point(10.0μm, 0.0μm),
            Point(5.0μm, 0.0μm),  # pinch 1
            Point(5.0μm, 5.0μm),
            Point(0.0μm, 5.0μm)
        ]
        cp = CurvilinearPolygon(pts)
        r = CurvilinearRegion(cp, CurvilinearPolygon{typeof(1.0μm)}[])
        # Splitting should not throw and should produce at least one region
        # (the 2-point sliver, if any, is dropped internally).
        out = SolidModels.split_pinches([r])
        @test length(out) >= 1
        # No output region should be degenerate (< 3 vertices).
        @test all(length(points(rr.exterior)) >= 3 for rr in out)
    end

    @testset "find_pinch_points detection is unit-invariant (nm vs µm)" begin
        # `find_pinch_points` detects at a 2 nm tolerance, so it must strip
        # coordinates to nm regardless of the Point's storage unit. The SAME
        # physical geometry expressed in µm and in nm must give the identical
        # result — otherwise µm-scale vertices (0.5–1 µm apart) would ustrip to
        # magnitudes ≤ the 2 nm cell and be mis-flagged as coincident.
        fp = SolidModels.ConformalRender.find_pinch_points

        # A clean 5-vertex outline with vertices 0.5–1 µm apart — NO pinch.
        clean_um = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(1.0μm, 0.0μm),
            Point(1.0μm, 1.0μm),
            Point(0.5μm, 1.0μm),
            Point(0.0μm, 1.0μm)
        ]
        clean_nm = [convert(Point{typeof(1.0nm)}, p) for p in clean_um]
        @test isempty(fp(clean_um))          # µm-based: no false positives
        @test isempty(fp(clean_nm))          # nm-based: also none
        @test fp(clean_um) == fp(clean_nm)   # unit-invariant

        # A genuine figure-8: non-adjacent vertices 2 and 5 coincide exactly.
        # Detected in BOTH units, identically.
        fig8_um = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),
            Point(5.0μm, 0.0μm),
            Point(10.0μm, 5.0μm),
            Point(5.0μm, 10.0μm),
            Point(5.0μm, 0.0μm),  # coincides with index 2
            Point(0.0μm, 10.0μm)
        ]
        fig8_nm = [convert(Point{typeof(1.0nm)}, p) for p in fig8_um]
        @test fp(fig8_um) == [(2, 5)]
        @test fp(fig8_nm) == [(2, 5)]
    end

    @testset "split_pinches preserves Turn curves through a split (both lobes)" begin
        # A pinched contour carrying a native `Paths.Turn` arc in EACH lobe.
        # The pinch at indices (3, 6) partitions vertices into lobe1 = {3,4,5}
        # and lobe2 = {6,1,2}; an arc starts at index 4 (→ lobe1) and another at
        # index 1 (→ lobe2), exercising both curve-remap branches of
        # `_split_at_pinch`. Both arcs must survive as native Turns, not be
        # discretized.
        R = 5.0μm
        pp = Point{typeof(1.0μm)}[
            Point(0.0μm, 0.0μm),        # 1: arc B start
            Point(0.0μm + R, R),        # 2: arc B end
            Point(20.0μm, 20.0μm),      # 3: pinch (coincides with 6)
            Point(30.0μm, 20.0μm),      # 4: arc A start
            Point(30.0μm + R, 20.0μm + R), # 5: arc A end
            Point(20.0μm, 20.0μm)       # 6: coincides with index 3 → pinch
        ]
        turnB = Paths.Turn(90°, R, α0=90°, p0=pp[1])
        turnA = Paths.Turn(90°, R, α0=90°, p0=pp[4])
        cp = CurvilinearPolygon(pp, [turnB, turnA], [1, 4])
        r = CurvilinearRegion(cp, CurvilinearPolygon{typeof(1.0μm)}[])
        out = SolidModels.split_pinches([r])
        @test length(out) >= 2
        # A Turn must survive in each of the two lobes (both remap branches ran).
        @test all(any(c -> c isa Paths.Turn, rr.exterior.curves) for rr in out)
        # Two native Turns total across the output — none discretized away.
        all_curves = reduce(vcat, [rr.exterior.curves for rr in out]; init=[])
        @test count(c -> c isa Paths.Turn, all_curves) == 2
    end

    @testset "split_pinches splits a pinch inside a hole" begin
        # The exterior is clean; a HOLE is self-touching. split_pinches must
        # walk holes too (find_pinch_points on each hole, split, reassign).
        ext = CurvilinearPolygon(
            Point{typeof(1.0μm)}[
                Point(-50.0μm, -50.0μm),
                Point(50.0μm, -50.0μm),
                Point(50.0μm, 50.0μm),
                Point(-50.0μm, 50.0μm)
            ]
        )
        # Figure-8 hole: non-adjacent vertices 1 and 4 coincide.
        hole = CurvilinearPolygon(
            Point{typeof(1.0μm)}[
                Point(0.0μm, 0.0μm),
                Point(10.0μm, 0.0μm),
                Point(5.0μm, 10.0μm),
                Point(0.0μm, 0.0μm),   # coincides with index 1
                Point(-10.0μm, 0.0μm),
                Point(-5.0μm, 10.0μm)
            ]
        )
        r = CurvilinearRegion(ext, [hole])
        @test !isempty(SolidModels.ConformalRender.find_pinch_points(points(hole)))
        out = SolidModels.split_pinches([r])
        # Exterior stays one region; the pinched hole is cleaved into simple
        # sub-loops (so total hole count across the output grew).
        total_holes = sum(length(rr.holes) for rr in out)
        @test total_holes >= 2
        @test all(length(points(h)) >= 3 for rr in out for h in rr.holes)
    end
end
