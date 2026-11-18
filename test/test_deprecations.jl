@testitem "Deprecations" setup = [CommonTestSetup, QuietGmshSetup] begin
    # Every deprecation is asserted here, so that the rest of the suite can stay quiet by
    # calling only current spellings. `@test_deprecated` covers `Base.depwarn` sites, which
    # fire under `--depwarn=yes` (as `Pkg.test` runs) and are silent otherwise; deprecations
    # with a new behavior to opt into warn at default visibility and are checked directly.

    @testset "connected_components non-boundary contact keywords" begin
        sm = SolidModel("deprecations_cc"; overwrite=true)
        SolidModels.gmsh.model.occ.addRectangle(0, 0, 0, 1, 1)
        SolidModels.gmsh.model.occ.addRectangle(5, 0, 0, 1, 1)
        SolidModels.gmsh.model.occ.synchronize()
        tags = Int32[1, 2]
        expected = SolidModels.connected_components(2, tags)
        @test (@test_deprecated SolidModels.connected_components(
            2,
            tags;
            detect_non_boundary_contacts=true
        )) == expected
        @test (@test_deprecated SolidModels.connected_components(
            2,
            tags;
            non_boundary_contact_tol=1e-3
        )) == expected
    end

    @testset "check_port_connectivity non-boundary contact keywords" begin
        sm = SolidModel("deprecations_cpc"; overwrite=true)
        SolidModels.gmsh.model.occ.addRectangle(0, 0, 0, 1, 1)
        SolidModels.gmsh.model.occ.addRectangle(5, 0, 0, 1, 1)
        SolidModels.gmsh.model.occ.synchronize()
        sm["metal"] = [(Int32(2), Int32(1)), (Int32(2), Int32(2))]
        expected = SolidModels.check_port_connectivity(sm, ["port"], ["metal"])
        @test (@test_deprecated SolidModels.check_port_connectivity(
            sm,
            ["port"],
            ["metal"];
            detect_non_boundary_contacts=true
        )) == expected
        @test (@test_deprecated SolidModels.check_port_connectivity(
            sm,
            ["port"],
            ["metal"];
            non_boundary_contact_tol=1e-3
        )) == expected
    end
end
