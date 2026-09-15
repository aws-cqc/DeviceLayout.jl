@testitem "Deprecations" setup = [CommonTestSetup, QuietGmshSetup] begin
    # Every deprecation is asserted here, so that the rest of the suite can stay quiet by
    # calling only current spellings. `@test_deprecated` covers `Base.depwarn` sites, which
    # fire under `--depwarn=yes` (as `Pkg.test` runs) and are silent otherwise; deprecations
    # with a new behavior to opt into warn at default visibility and are checked directly.
    using DeviceLayout.SchematicDrivenLayout: filter_parameters
    import DeviceLayout.SchematicDrivenLayout.ExamplePDK
    using DeviceLayout.SchematicDrivenLayout.ExamplePDK.Transmons:
        ExampleRectangleTransmon, ExampleRectangleIsland

    @testset "layers -> gdslayers" begin
        c = Cell("deprecations", nm)
        render!(c, centered(Rectangle(2μm, 2μm)), GDSMeta(3, 1))
        @test (@test_deprecated layers(c)) == gdslayers(c) == [3]
    end

    @testset "cliptree -> clip(...).tree" begin
        r1 = centered(Rectangle(2μm, 2μm))
        r2 = centered(Rectangle(1μm, 1μm))
        tree = @test_deprecated cliptree(Clipper.ClipTypeDifference, r1, r2)
        @test to_polygons(ClippedPolygon(tree)) ==
              to_polygons(clip(Clipper.ClipTypeDifference, r1, r2))
    end

    @testset "non-finite selection_tolerance" begin
        # Default-visible warning: the replacement is a behavior change, not a rename.
        sty =
            @test_logs (:warn, r"Non-finite `selection_tolerance`") match_mode = :any Rounded(
                1μm,
                p0=[Point(1μm, 1μm)]
            )
        @test !isfinite(sty.selection_tolerance)
        @test_nowarn Rounded(1μm, p0=[Point(1μm, 1μm)], selection_tolerance=1nm)
    end

    @testset "Ellipse rounded keyword" begin
        e = Ellipse(Point(0μm, 0μm), (2μm, 1μm), 45°)
        sm = SolidModel("deprecations"; overwrite=true)
        @test (@test_deprecated SolidModels.to_primitives(sm, e; rounded=true)) === e
        @test length(
            points(@test_deprecated SolidModels.to_primitives(sm, e; rounded=false))
        ) == 8
        smg = SolidModel("deprecations_gmsh", SolidModels.GmshNative(); overwrite=true)
        @test length(
            points(@test_deprecated SolidModels.to_primitives(smg, e; rounded=false))
        ) == 8
    end

    @testset "render! meshing_parameters" begin
        sm = SolidModel("deprecations"; overwrite=true)
        @test_deprecated render!(
            sm,
            CoordinateSystem("deprecations", nm),
            meshing_parameters=SolidModels.MeshingParameters()
        )
        # `apply_size_to_surfaces` has no replacement; it warns and is ignored.
        @test_deprecated r"`apply_size_to_surfaces` is deprecated" render!(
            sm,
            CoordinateSystem("deprecations", nm),
            meshing_parameters=SolidModels.MeshingParameters(apply_size_to_surfaces=true)
        )
    end

    @testset "ExamplePDK filter_params" begin
        tr = ExampleRectangleTransmon()
        @test (@test_deprecated ExamplePDK.filter_params(ExampleRectangleIsland, tr)) ==
              filter_parameters(ExampleRectangleIsland, tr)
    end
end
