@testitem "Deprecations" setup = [CommonTestSetup, QuietGmshSetup] begin
    # Every deprecation is asserted here, so that the rest of the suite can stay quiet by
    # calling only current spellings. `@test_deprecated` covers `Base.depwarn` sites, which
    # fire under `--depwarn=yes` (as `Pkg.test` runs) and are silent otherwise; deprecations
    # with a new behavior to opt into warn at default visibility and are checked directly.
    using DeviceLayout.SchematicDrivenLayout: filter_parameters
    import DeviceLayout.SchematicDrivenLayout.ExamplePDK
    using DeviceLayout.SchematicDrivenLayout.ExamplePDK.Transmons:
        ExampleRectangleTransmon, ExampleRectangleIsland

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
end
