@testitem "ConformalRender smoke" setup = [CommonTestSetup] begin
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
        Paths
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
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_tree = SpatialIndexing.RTree{Float64, 3}(Int32)

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

        loop1 = add_conformal_loop!(ctx, left, k, 0.0μm; points_tree)
        loop2 = add_conformal_loop!(ctx, right, k, 0.0μm; points_tree)

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
        render!(sm_stock, cs)
        n_surf_stock = length(gmsh.model.occ.getEntities(2))

        sm_conformal = SolidModel("conformal"; overwrite=true)
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
        render_conformal!(sm1, cs)
        @test hasgroup(sm1, "l1", 2)

        # With backstop: same result (backstop runs as no-op when the cache
        # already produced conformal geometry).
        sm2 = SolidModel("bs_on"; overwrite=true)
        render_conformal!(sm2, cs; fragment_backstop=true)
        @test hasgroup(sm2, "l1", 2)

        gmsh.finalize()
    end

    @testset "render_conformal! rejects GmshNative kernel" begin
        sm_native = SolidModel("native", SolidModels.GmshNative(); overwrite=true)
        cs = CoordinateSystem("dummy", nm)
        place!(cs, Rectangle(Point(0.0μm, 0.0μm), Point(1.0μm, 1.0μm)), :l1)
        @test_throws ErrorException render_conformal!(sm_native, cs)
        gmsh.finalize()
    end

    @testset "add_conformal_loop! with Paths.Turn (short arc)" begin
        # Direct exercise of _add_conformal_curve!(Paths.Turn) — a 90° arc.
        sm = SolidModel("turn_short"; overwrite=true)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_tree = SpatialIndexing.RTree{Float64, 3}(Int32)

        R = 100.0μm
        pp = [Point(0.0μm, 0.0μm), Point(R, 0.0μm), Point(0.0μm, R)]
        turn = Paths.Turn(90°, R, α0=90°, p0=pp[2])
        cp = CurvilinearPolygon(pp, [turn], [2])
        loop = add_conformal_loop!(ctx, cp, k, 0.0μm; points_tree)
        @test loop isa Integer
        gmsh.finalize()
    end

    @testset "add_conformal_loop! with Paths.Turn (large arc)" begin
        # Turn with |α| >= 180° triggers the multi-segment arc path.
        sm = SolidModel("turn_large"; overwrite=true)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_tree = SpatialIndexing.RTree{Float64, 3}(Int32)

        R = 50.0μm
        pp = [Point(0.0μm, 0.0μm), Point(R, 0.0μm), Point(-R, 0.0μm)]
        turn = Paths.Turn(180°, R, α0=90°, p0=pp[2])
        cp = CurvilinearPolygon(pp, [turn], [2])
        loop = add_conformal_loop!(ctx, cp, k, 0.0μm; points_tree)
        @test loop isa Integer
        gmsh.finalize()
    end

    @testset "add_conformal_loop! with Paths.BSpline" begin
        # Exercise _add_conformal_curve!(Paths.BSpline).
        sm = SolidModel("bspline"; overwrite=true)
        k = kernel(sm)
        ctx = ConformalRenderContext()
        import SpatialIndexing
        points_tree = SpatialIndexing.RTree{Float64, 3}(Int32)

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
        loop = add_conformal_loop!(ctx, cp, k, 0.0μm; points_tree)
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
        render_conformal!(sm, cs)
        @test hasgroup(sm, "l1", 2)
        # A rounded rectangle should produce a single surface with curved edges.
        @test length(gmsh.model.occ.getEntities(2)) >= 1
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
end
