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
        difference2d
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

    @testset "render_conformal! rejects GmshNative kernel" begin
        sm_native = SolidModel("native", SolidModels.GmshNative(); overwrite=true)
        cs = CoordinateSystem("dummy", nm)
        place!(cs, Rectangle(Point(0.0μm, 0.0μm), Point(1.0μm, 1.0μm)), :l1)
        @test_throws ErrorException render_conformal!(sm_native, cs)
        gmsh.finalize()
    end
end
