@testitem "SolidModel CAD import" setup = [CommonTestSetup] begin
    import DeviceLayout: ScaledIsometry, Point
    using DeviceLayout.SolidModels
    import DeviceLayout.SolidModels: import_solid!, dimtags, gmsh, GmshNative, _postrender!

    # Create a temporary external-style CAD source: a 10 μm cube at the origin
    # with volume 1000 μm³ and centroid (5, 5, 5). Build it in a separate Gmsh
    # model, export it to BREP, and discard the source model before importing it
    # into `chip`. Constructing `chip` first also initializes Gmsh.
    chip = SolidModel("import_chip"; overwrite=true)
    brep = joinpath(tdir, "box.brep")
    gmsh.model.add("authoring")
    gmsh.model.occ.addBox(0, 0, 0, 10, 10, 10)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    # Convenience probes: volume (getMass on a 3D entity) and centroid of a physical group.
    vol(pg) = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(pg))
    com(pg) = gmsh.model.occ.getCenterOfMass(dimtags(pg)[1]...)

    @testset "places an imported solid at a hook-style pose" begin
        # Rotate 90° CCW, translate to (100, 50)μm, lift z = 20μm.
        place = ScaledIsometry(Point(100μm, 50μm), 90°, false, 1.0)
        new_dimtags = import_solid!(chip, brep; transform=place, z=20μm, groupname="part")
        @test unique(first.(new_dimtags)) == Int32[3] # Volume, not a shell.
        pg = chip["part", 3]
        # Cross-check the hand-built 3D OCC affine against DeviceLayout's own (independent) 2D
        # transform application: the source centroid (5,5) must land where `place` sends it.
        expected_centroid = place(Point(5μm, 5μm))
        c = com(pg)
        @test c[1] ≈ ustrip(μm, getx(expected_centroid)) atol = 1e-6
        @test c[2] ≈ ustrip(μm, gety(expected_centroid)) atol = 1e-6
        @test c[3] ≈ 25.0 atol = 1e-6                   # source z (5) + 20μm lift
    end

    @testset "volume is invariant under rigid placement" begin
        # A rotation + translation is an isometry, so the imported volume must be unchanged
        # regardless of the (non-cardinal) angle or offset chosen.
        s1 = SolidModel("import_rigid"; overwrite=true)
        import_solid!(
            s1,
            brep;
            transform=ScaledIsometry(Point(7μm, -3μm), 33°, false, 1.0),
            z=4μm,
            groupname="part"
        )
        @test vol(s1["part", 3]) ≈ 1000.0 atol = 1e-6
    end

    @testset "uniform scale scales volume as the cube (default-z regression)" begin
        # No `z` kwarg here, which exercises the default z (= 0.0 * STP_UNIT). A default of
        # `zero(STP_UNIT)` — zero of a bare unit — used to throw; this guards that path.
        s2 = SolidModel("import_scaled"; overwrite=true)
        import_solid!(s2, brep; scale=2.0, groupname="part")
        @test vol(s2["part", 3]) ≈ 8000.0 atol = 1e-6   # (2^3) * 1000
        @test com(s2["part", 3])[3] ≈ 10.0 atol = 1e-6  # centroid z = 5 scaled by 2, no lift
    end

    @testset "reflection and in-plane magnification match ScaledIsometry" begin
        reflected = SolidModel("import_reflected"; overwrite=true)
        place = ScaledIsometry(Point(40μm, -20μm), 30°, true, 2.0)
        import_solid!(reflected, brep; transform=place, z=7μm, groupname="part")

        expected_centroid = place(Point(5μm, 5μm))
        c = com(reflected["part", 3])
        @test c[1] ≈ ustrip(μm, getx(expected_centroid)) atol = 1e-6
        @test c[2] ≈ ustrip(μm, gety(expected_centroid)) atol = 1e-6
        @test c[3] ≈ 12.0 atol = 1e-6              # mag affects x/y; source z (5) + 7μm lift
        @test vol(reflected["part", 3]) ≈ 4000.0 atol = 1e-6  # (2^2) * 1000
    end

    @testset "imported solid is watertight / meshable" begin
        # The strongest correctness gate for downstream FEM use: a valid closed solid meshes
        # in 3D without error and produces volume elements.
        s3 = SolidModel("import_mesh"; overwrite=true)
        import_solid!(s3, brep; groupname="part")
        gmsh.model.set_current("import_mesh")
        gmsh.model.mesh.generate(3)
        _, etags, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, etags) > 0
    end

    @testset "groupname=nothing returns dimtags without creating a group" begin
        s4 = SolidModel("import_nogroup"; overwrite=true)
        new_dimtags = import_solid!(s4, brep; groupname=nothing)
        @test unique(first.(new_dimtags)) == Int32[3]
        @test !SolidModels.hasgroup(s4, "imported", 3)
    end

    @testset "postrender operation creates only the destination group" begin
        s5 = SolidModel("import_postrender"; overwrite=true)
        place = ScaledIsometry(Point(12μm, 8μm), 90°, false, 1.0)
        operations = [(
            "part",
            import_solid!,
            (brep,),
            :transform => place,
            :z => 3μm,
            :groupname => nothing
        )]
        _postrender!(s5, operations)

        @test SolidModels.hasgroup(s5, "part", 3)
        @test !SolidModels.hasgroup(s5, "imported", 3)
        expected_centroid = place(Point(5μm, 5μm))
        c = com(s5["part", 3])
        @test c[1] ≈ ustrip(μm, getx(expected_centroid)) atol = 1e-6
        @test c[2] ≈ ustrip(μm, gety(expected_centroid)) atol = 1e-6
        @test c[3] ≈ 8.0 atol = 1e-6
    end

    @testset "input validation" begin
        # Missing file is rejected up front.
        @test_throws ArgumentError import_solid!(
            chip,
            joinpath(tdir, "does_not_exist.brep")
        )
        # The GmshNative kernel can neither read CAD nor do booleans, so import is rejected
        # (the kernel check runs before the file check, so a real file still throws here).
        native = SolidModel("import_native", GmshNative(); overwrite=true)
        @test_throws ArgumentError import_solid!(native, brep)
    end
end
