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

@testitem "SolidModel CAD import conformal fusion" setup = [CommonTestSetup] begin
    using DeviceLayout.SolidModels
    import DeviceLayout.SolidModels: import_solid!, dimtags, gmsh, _fragment_and_map!

    # Verify that imported and native solids become conformal after render's fragment/remap pass.
    # A conformal interface is one topological face shared by both volumes.

    # Export a 10 μm cube as external CAD.
    chip = SolidModel("fuse_chip"; overwrite=true)
    brep = joinpath(tdir, "fuse_cube.brep")
    gmsh.model.add("authoring")
    gmsh.model.occ.addBox(0, 0, 0, 10, 10, 10)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    # Add a pad whose top face coincides with the cube's base.
    gmsh.model.set_current("fuse_chip")
    pad = gmsh.model.occ.addBox(-10, -10, -5, 30, 30, 5)
    chip["pad_metal"] = [(3, pad)]

    import_solid!(chip, brep; groupname="part")

    faceset(pg) =
        Set(abs(t) for (d, t) in gmsh.model.getBoundary(dimtags(pg), false, false, false))
    vol(pg) = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(pg))

    @testset "coincident faces are distinct before fusion" begin
        @test isempty(intersect(faceset(chip["part", 3]), faceset(chip["pad_metal", 3])))
    end

    _fragment_and_map!(chip, [2, 3])

    @testset "fusion makes the shared interface conformal" begin
        shared = intersect(faceset(chip["part", 3]), faceset(chip["pad_metal", 3]))
        @test length(shared) == 1

        # Fragmentation preserves the total volume of the touching solids.
        @test vol(chip["part", 3]) + vol(chip["pad_metal", 3]) ≈ 5500.0 atol = 1e-6

        gmsh.model.mesh.generate(3)
        _, etags, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, etags) > 0
    end
end

@testitem "SolidModel CAD import — base/pedestals/chip stack" setup = [CommonTestSetup] begin
    using DeviceLayout.SolidModels
    import DeviceLayout.SolidModels: import_solid!, dimtags, gmsh, _fragment_and_map!

    # Exercise conformal fusion across a base, four pedestals, an imported chip, and vacuum.

    sm = SolidModel("stack"; overwrite=true)

    # Export the chip separately so the test covers external CAD import.
    chipfile = joinpath(tdir, "stack_chip.brep")
    gmsh.model.add("stack_chip_author")
    gmsh.model.occ.addBox(-20, -20, -10, 40, 40, 20)
    gmsh.model.occ.synchronize()
    gmsh.write(chipfile)
    gmsh.model.remove()

    gmsh.model.set_current("stack")
    occ = gmsh.model.occ
    # Extrude from one face so base and vacuum share topology along their full-footprint interface.
    # Separate coincident boxes leave duplicate exterior facets that TetGen cannot recover.
    iface  = occ.addRectangle(-50, -50, -30, 100, 100)                # interface at z=-30
    downdt = occ.extrude([(Int32(2), Int32(iface))], 0, 0, -20.0)    # base   z[-50,-30]
    updt   = occ.extrude([(Int32(2), Int32(iface))], 0, 0, 80.0)    # vacuum z[-30,50]
    occ.synchronize()
    sm["base"] = [dt for dt in downdt if dt[1] == 3]
    sm["vacuum"] = [dt for dt in updt if dt[1] == 3]
    peds = [
        (Int32(3), Int32(occ.addBox(x0, y0, -30, 8, 8, 20)))         # on base top, top z=-10
        for (x0, y0) in ((10, 10), (10, -18), (-18, 10), (-18, -18))
    ]
    sm["pedestals"] = peds

    import_solid!(sm, chipfile; groupname="chip")

    vol(pg) = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(pg))
    faceset(pg) =
        Set(abs(t) for (d, t) in gmsh.model.getBoundary(dimtags(pg), false, false, false))
    shared(a, b) = length(intersect(faceset(sm[a, 3]), faceset(sm[b, 3])))

    @test vol(sm["base", 3]) ≈ 200000.0 atol = 1e-3       # 100×100×20
    @test vol(sm["chip", 3]) ≈ 32000.0 atol = 1e-3        # 40×40×20
    @test vol(sm["pedestals", 3]) ≈ 5120.0 atol = 1e-3    # 4 × 8×8×20

    _fragment_and_map!(sm, [2, 3])

    # Fragmentation preserves ancestry, so remove solid-owned volumes from the background vacuum.
    vtags(pg) = Set(t for (d, t) in dimtags(pg))
    solid_tags =
        union(vtags(sm["base", 3]), vtags(sm["pedestals", 3]), vtags(sm["chip", 3]))
    sm["vacuum"] = [(3, t) for (d, t) in dimtags(sm["vacuum", 3]) if !(t in solid_tags)]

    @testset "multi-body conformal interfaces" begin
        @test shared("base", "pedestals") == 4
        @test shared("pedestals", "chip") == 4
        # Fragmentation may subdivide the base-vacuum interface around pedestal footprints.
        @test shared("base", "vacuum") >= 1
    end

    @testset "vacuum is the exclusive material complement" begin
        # After solid precedence, no volume is owned by both the vacuum and a solid group...
        @test isempty(intersect(vtags(sm["vacuum", 3]), solid_tags))
        # ...and the vacuum equals the enclosure minus the inclusions:
        # 100×100×80 − chip(32000) − pedestals(5120) = 762880 µm³.
        @test vol(sm["vacuum", 3]) ≈ 762880.0 atol = 1e-3
    end

    @testset "stack meshes" begin
        gmsh.model.mesh.generate(3)
        _, etags, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, etags) > 0
    end
end
