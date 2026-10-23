@testitem "SolidModel CAD import" setup = [CommonTestSetup, QuietGmshSetup] begin
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

    # A box and a cylinder in a STEP and a BREP file, to check surface types after
    # placement.
    gmsh.model.add("authoring_mixed")
    gmsh.model.occ.addBox(0, 0, 0, 10, 10, 10)
    gmsh.model.occ.addCylinder(20, 0, 0, 0, 0, 10, 3)
    gmsh.model.occ.synchronize()
    step = joinpath(tdir, "mixed.step")
    brep_mixed = joinpath(tdir, "mixed.brep")
    gmsh.write(step)
    gmsh.write(brep_mixed)
    gmsh.model.remove()
    function surface_types(sm)
        gmsh.model.set_current(SolidModels.name(sm))
        return Set(gmsh.model.getType(2, t) for (_, t) in gmsh.model.getEntities(2))
    end

    @testset "STEP import with placement and scale" begin
        s6 = SolidModel("import_step"; overwrite=true)
        place = ScaledIsometry(Point(100μm, 50μm), 90°, false, 1.0)
        new = import_solid!(s6, step; transform=place, z=20μm, scale=2.0, groupname="part")
        @test length(new) == 2 && unique(first.(new)) == Int32[3]
        vols = sort([gmsh.model.occ.getMass(d, t) for (d, t) in new])
        @test vols[1] ≈ 2^3 * π * 3^2 * 10 atol = 1e-3   # cylinder r=3, h=10, scaled by 2
        @test vols[2] ≈ 2^3 * 1000 atol = 1e-3
        # The box centroid (5, 5, 5) scales to (10, 10, 10), then `place` and the lift
        # apply.
        box = only(dt for dt in new if gmsh.model.occ.getMass(dt...) ≈ 8000)
        c = gmsh.model.occ.getCenterOfMass(box...)
        expected = place(Point(10μm, 10μm))
        @test c[1] ≈ ustrip(μm, getx(expected)) atol = 1e-6
        @test c[2] ≈ ustrip(μm, gety(expected)) atol = 1e-6
        @test c[3] ≈ 30.0 atol = 1e-6
    end

    @testset "rotation, translation, and scale keep analytic surfaces" begin
        place = ScaledIsometry(Point(7μm, -3μm), 33°, false, 1.0)
        for (nm, file) in
            (("import_analytic_step", step), ("import_analytic_brep", brep_mixed))
            sa = SolidModel(nm; overwrite=true)
            import_solid!(sa, file; transform=place, z=4μm, scale=1000.0, groupname="part")
            @test surface_types(sa) == Set(["Plane", "Cylinder"])
        end
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

@testitem "SolidModel CAD import from .xao with physical groups" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    import DeviceLayout: ScaledIsometry, Point
    using DeviceLayout.SolidModels
    import DeviceLayout.SolidModels: import_solid!, dimtags, dimgroupdict, gmsh, hasgroup

    # Author a two-solid part with physical groups in every dimension that matters, save it as
    # .xao, and discard the source model. The groups get the lowest tags gmsh hands out, which
    # is exactly what a fresh destination model's own first groups also get.
    src = SolidModel("xao_author"; overwrite=true)
    gmsh.model.set_current("xao_author")
    a = gmsh.model.occ.addBox(0, 0, 0, 10, 10, 10)
    b = gmsh.model.occ.addBox(10, 0, 0, 10, 10, 10)     # shares the x = 10 face with `a`
    gmsh.model.occ.fragment([(3, a)], [(3, b)])
    gmsh.model.occ.synchronize()
    src["left"] = [(3, a)]
    src["right"] = [(3, b)]
    tops =
        [(2, t) for (_, t) in gmsh.model.getEntitiesInBoundingBox(-1, -1, 9, 21, 11, 11, 2)]
    src["top"] = tops
    xao = joinpath(tdir, "part.xao")
    DeviceLayout.save(xao, src)
    gmsh.model.remove()

    vol(pg) = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(pg))
    com(pg) = gmsh.model.occ.getCenterOfMass(dimtags(pg)[1]...)

    @testset "file groups survive a tag collision with existing groups" begin
        sm = SolidModel("xao_dest"; overwrite=true)
        gmsh.model.set_current("xao_dest")
        c = gmsh.model.occ.addBox(100, 100, 100, 1, 1, 1)
        gmsh.model.occ.synchronize()
        sm["existing"] = [(3, c)]                # dim-3 tag 1, same as `left` in the file
        new = import_solid!(sm, xao; groupname="part")
        @test unique(first.(new)) == Int32[3]    # only the two solids, not their boundary
        @test length(new) == 2
        @test length(dimtags(sm["existing", 3])) == 1
        @test length(dimtags(sm["left", 3])) == 1
        @test length(dimtags(sm["right", 3])) == 1
        @test length(dimtags(sm["top", 2])) == 2
        @test length(dimtags(sm["part", 3])) == 2
        @test vol(sm["left", 3]) ≈ 1000.0 atol = 1e-6
        # The shared face is still shared: the imported part stays conformal.
        shared = intersect(
            Set(
                abs(t) for (_, t) in
                gmsh.model.getBoundary(dimtags(sm["left", 3]), false, false, false)
            ),
            Set(
                abs(t) for (_, t) in
                gmsh.model.getBoundary(dimtags(sm["right", 3]), false, false, false)
            )
        )
        @test length(shared) == 1
    end

    @testset "group_map renames, nothing discards, placement applies" begin
        sm = SolidModel("xao_mapped"; overwrite=true)
        place = ScaledIsometry(Point(100μm, 50μm), 90°, false, 1.0)
        import_solid!(
            sm,
            xao;
            transform=place,
            z=20μm,
            scale=2.0,
            groupname=nothing,
            group_map=n -> n * "_pkg"
        )
        @test hasgroup(sm, "left_pkg", 3) && hasgroup(sm, "top_pkg", 2)
        @test !hasgroup(sm, "left", 3) && !hasgroup(sm, "imported", 3)
        @test vol(sm["left_pkg", 3]) ≈ 8000.0 atol = 1e-6          # scale cubed
        expected = place(Point(10μm, 10μm))                          # scaled centroid (5,5)·2
        c = com(sm["left_pkg", 3])
        @test c[1] ≈ ustrip(μm, getx(expected)) atol = 1e-6
        @test c[2] ≈ ustrip(μm, gety(expected)) atol = 1e-6
        @test c[3] ≈ 30.0 atol = 1e-6                                # 5·2 + 20 lift
        # The face group moved with the solids: its faces are still on their boundary, at the
        # placed top (z = 10·2 + 20).
        bdry = Set(
            abs(t) for (_, t) in gmsh.model.getBoundary(
                vcat(dimtags(sm["left_pkg", 3]), dimtags(sm["right_pkg", 3])),
                false,
                false,
                false
            )
        )
        @test length(dimtags(sm["top_pkg", 2])) == 2
        @test Set(t for (_, t) in dimtags(sm["top_pkg", 2])) ⊆ bdry
        for (_, t) in dimtags(sm["top_pkg", 2])
            bb = gmsh.model.getBoundingBox(2, t)
            @test bb[3] ≈ 40.0 atol = 1e-3
            @test bb[6] ≈ 40.0 atol = 1e-3
        end

        sd = SolidModel("xao_discard"; overwrite=true)
        import_solid!(sd, xao; group_map=nothing)
        @test isempty(dimgroupdict(sd, 2))
        @test collect(keys(dimgroupdict(sd, 3))) == ["imported"]
    end
end

@testitem "SolidModel CAD import conformal fusion" setup = [CommonTestSetup, QuietGmshSetup] begin
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

@testitem "SolidModel CAD import — base/pedestals/chip stack" setup =
    [CommonTestSetup, QuietGmshSetup] begin
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

@testitem "SolidModelComponent renders + meshes in a schematic" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent
    import DeviceLayout.SolidModels: gmsh, hasgroup, dimtags
    using DeviceLayout: SemanticMeta, GDSMeta

    # Author a 10 μm cube as external CAD.
    _tmp = SolidModel("smc_author"; overwrite=true)
    brep = joinpath(tdir, "smc_cube.brep")
    gmsh.model.add("smc_auth")
    gmsh.model.occ.addBox(-5, -5, -5, 10, 10, 10)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    reset_uniquename!()
    g = SchematicGraph("smc")
    smc = SolidModelComponent(brep, SemanticMeta(:chip_outline); name="cad")
    cad_id = add_node!(g, smc).id
    sch = plan(g; log_dir=nothing)
    check!(sch)

    tech = ProcessTechnology((; chip_outline=GDSMeta()), (;))
    target = SolidModelTarget(tech)
    sm = SolidModel("smc"; overwrite=true)
    @test_nowarn render!(sm, sch, target)

    @testset "component imported as its own physical group" begin
        @test hasgroup(sm, cad_id, 3)                # named after the node id
        vol = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(sm[cad_id, 3]))
        @test vol ≈ 1000.0 atol = 1e-6
    end

    @testset "meshes" begin
        gmsh.model.set_current("smc")
        gmsh.model.mesh.generate(3)
        _, et, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, et) > 0
    end
end

@testitem "SolidModelComponent lands at its hook-mated pose" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent, Spacer
    import DeviceLayout.SolidModels: gmsh, dimtags
    using DeviceLayout: SemanticMeta, GDSMeta, Point

    # Author a 10 μm cube centred at the origin (centroid (0,0,0) in its own frame).
    _tmp = SolidModel("smc2_author"; overwrite=true)
    brep = joinpath(tdir, "smc2_cube.brep")
    gmsh.model.add("smc2_auth")
    gmsh.model.occ.addBox(-5, -5, -5, 10, 10, 10)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    # Place the component not at the origin: mate it to a Spacer whose far hook is at (100,50)μm.
    # A centred cube's centroid follows the component origin, so after mating it must sit at (100,50).
    reset_uniquename!()
    g = SchematicGraph("smc2")
    sp_node = add_node!(g, Spacer(; p1=Point(100μm, 50μm)))
    fuse!(
        g,
        sp_node => :p1_east,
        SolidModelComponent(brep, SemanticMeta(:chip_outline); name="cad") => :west
    )
    sch = plan(g; log_dir=nothing)
    check!(sch)

    tech = ProcessTechnology((; chip_outline=GDSMeta()), (;))
    sm = SolidModel("smc2"; overwrite=true)
    @test_nowarn render!(sm, sch, SolidModelTarget(tech))

    # The imported cube must have moved to the mated pose (rotation-invariant: centroid = mate point).
    grp = only(
        filter(
            n -> startswith(n, "cad"),
            collect(keys(SchematicDrivenLayout.SolidModels.dimgroupdict(sm, 3)))
        )
    )
    c = gmsh.model.occ.getCenterOfMass(dimtags(sm[grp, 3])[1]...)
    @test c[1] ≈ 100.0 atol = 1e-6
    @test c[2] ≈ 50.0 atol = 1e-6

    gmsh.model.set_current("smc2")
    gmsh.model.mesh.generate(3)
    _, et, _ = gmsh.model.mesh.getElements(3)
    @test sum(length, et) > 0
end

@testitem "SolidModelComponent fuses with schematic geometry" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent
    import DeviceLayout.SolidModels: gmsh, dimtags, hasgroup
    using DeviceLayout: SemanticMeta, GDSMeta, Rectangle, centered

    # External CAD: a 40 μm cube whose base is at z=0 (so it rests on the substrate top plane).
    _tmp = SolidModel("smcf_author"; overwrite=true)
    brep = joinpath(tdir, "smcf_cube.brep")
    gmsh.model.add("smcf_auth")
    gmsh.model.occ.addBox(-20, -20, 0, 40, 40, 40)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    # Schematic: one SolidModelComponent at the origin, plus a 2D chip-outline rectangle that
    # extrudes into a substrate directly beneath it. The render fragment pass should fuse them.
    reset_uniquename!()
    g = SchematicGraph("smcf")
    cad_id =
        add_node!(g, SolidModelComponent(brep, SemanticMeta(:chip_outline); name="cad")).id
    floorplan = plan(g; log_dir=nothing)
    render!(
        floorplan.coordinate_system,
        centered(Rectangle(200μm, 200μm)),
        SemanticMeta(:chip_outline)
    )
    check!(floorplan)

    substrate_z = 50μm
    tech = ProcessTechnology(
        (; chip_outline=GDSMeta()),
        (; thickness=(; chip_outline=[substrate_z]), chip_thicknesses=[substrate_z])
    )
    # `substrate_layers` makes chip_outline extrude DOWNWARD (z=-50…0), so the substrate sits
    # beneath the z=0 plane and the cube (z=0…40) rests on top — a touching interface. Without
    # it the layer extrudes upward (z=0…50) and the cube would be buried inside the substrate.
    target = SolidModelTarget(
        tech;
        levelwise_layers=[:chip_outline],
        substrate_layers=[:chip_outline]
    )
    sm = SolidModel("smcf"; overwrite=true)
    @test_nowarn render!(sm, floorplan, target)

    faceset(grp) = Set(
        abs(t) for
        (d, t) in gmsh.model.getBoundary(dimtags(sm[grp, 3]), false, false, false)
    )

    @testset "component + substrate present and conformal" begin
        @test hasgroup(sm, cad_id, 3)                        # imported CAD group
        @test hasgroup(sm, "chip_outline_L1_extrusion", 3)   # extruded substrate
        # The cube rests on the substrate top → the fragment pass makes a shared interface face.
        @test !isempty(intersect(faceset(cad_id), faceset("chip_outline_L1_extrusion")))
    end

    @testset "meshes" begin
        gmsh.model.set_current("smcf")
        gmsh.model.mesh.generate(3)
        _, et, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, et) > 0
    end
end

@testitem "SolidModelComponent fragment modes and file groups" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent, Spacer
    import DeviceLayout.SolidModels: gmsh, dimtags, hasgroup, dimgroupdict
    using DeviceLayout: SemanticMeta, GDSMeta, Rectangle, centered, Point

    # External CAD as .xao so it carries a face group: a 40 μm cube resting on z = 0, with its
    # top face in a group named "lid".
    _tmp = SolidModel("smcm_author"; overwrite=true)
    gmsh.model.set_current("smcm_author")
    b = gmsh.model.occ.addBox(-20, -20, 0, 40, 40, 40)
    gmsh.model.occ.synchronize()
    _tmp["cube"] = [(3, b)]
    _tmp["lid"] = [
        (2, t) for
        (_, t) in gmsh.model.getEntitiesInBoundingBox(-21, -21, 39, 21, 21, 41, 2)
    ]
    xao = joinpath(tdir, "smcm_cube.xao")
    DeviceLayout.save(xao, _tmp)
    gmsh.model.remove()

    tech = ProcessTechnology(
        (; chip_outline=GDSMeta()),
        (; thickness=(; chip_outline=[50μm]), chip_thicknesses=[50μm])
    )
    target = SolidModelTarget(
        tech;
        levelwise_layers=[:chip_outline],
        substrate_layers=[:chip_outline]
    )

    # Substrate extruded downward from a chip-outline rectangle, with `n` cubes resting on its
    # top plane side by side.
    function build(fragment; n=1, target=target)
        reset_uniquename!()
        g = SchematicGraph("smcm_$fragment")
        # Cube centres at the spacer's ends, 60 μm apart, leaving a 20 μm gap between cubes.
        sp = add_node!(g, Spacer(; p1=Point(60μm, 0μm)))
        cube() = SolidModelComponent(xao, SemanticMeta(:chip_outline); name="cad")
        ends = [sp => :p0_west, sp => :p1_east][1:n]
        mates = [:east, :west]
        ids = [fuse!(g, e, cube() => m).id for (e, m) in zip(ends, mates)]
        fp = plan(g; log_dir=nothing)
        render!(
            fp.coordinate_system,
            centered(Rectangle(200μm, 200μm)),
            SemanticMeta(:chip_outline)
        )
        check!(fp)
        sm = SolidModel("smcm_$fragment"; overwrite=true)
        kw = isnothing(fragment) ? (;) : (; component_fragment=fragment)
        render!(sm, fp, target; kw...)
        return sm, ids
    end
    faceset(sm, grp) = Set(
        abs(t) for
        (_, t) in gmsh.model.getBoundary(dimtags(sm[grp, 3]), false, false, false)
    )
    shared(sm, a, b="chip_outline_L1_extrusion") = intersect(faceset(sm, a), faceset(sm, b))

    @testset ":near fragments locally and keeps mapped file groups" begin
        sm, (id,) = build(:near)
        @test hasgroup(sm, id, 3)
        @test hasgroup(sm, "$(id)_cube", 3)      # file group, prefixed with the node id
        @test hasgroup(sm, "$(id)_lid", 2)
        @test length(shared(sm, id)) == 1        # one shared interface face
        @test length(dimtags(sm["$(id)_lid", 2])) == 1
    end

    @testset ":global fuses through the global pass, and is the default" begin
        for fragment in (:global, nothing)
            sm, (id,) = build(fragment)
            @test length(shared(sm, id)) == 1
        end
    end

    @testset ":near fragments all parts in one call, keeping their groups apart" begin
        sm, ids = build(:near; n=2)
        @test length(ids) == 2
        for id in ids
            @test length(dimtags(sm[id, 3])) == 1
            @test length(shared(sm, id)) == 1
        end
        # No group beyond the parts' own and their file groups.
        @test Set(keys(dimgroupdict(sm, 3))) ==
              Set(["chip_outline_L1_extrusion"; ids; ids .* "_cube"])
    end

    @testset "mode from the target's rendering options" begin
        sm, (id,) = build(
            nothing;
            target=SolidModelTarget(
                tech;
                levelwise_layers=[:chip_outline],
                substrate_layers=[:chip_outline],
                component_fragment=:near
            )
        )
        @test length(shared(sm, id)) == 1
    end

    @test_throws ArgumentError build(:sideways)
end

@testitem "SolidModelComponent placed in several nodes" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent, Spacer, component, nodes
    import DeviceLayout.SolidModels: gmsh, dimtags, hasgroup
    using DeviceLayout: SemanticMeta, GDSMeta, Point

    # A connector-like part as .xao with its own groups: a 10 μm cube "body" and its top
    # face "pin".
    _tmp = SolidModel("smcn_author"; overwrite=true)
    gmsh.model.set_current("smcn_author")
    b = gmsh.model.occ.addBox(-5, -5, 0, 10, 10, 10)
    gmsh.model.occ.synchronize()
    _tmp["body"] = [(3, b)]
    _tmp["pin"] =
        [(2, t) for (_, t) in gmsh.model.getEntitiesInBoundingBox(-6, -6, 9, 6, 6, 11, 2)]
    xao = joinpath(tdir, "smcn_connector.xao")
    DeviceLayout.save(xao, _tmp)
    gmsh.model.remove()

    # The same component in three nodes: at both ends of one spacer and at the far end of a
    # second spacer attached to the first.
    reset_uniquename!()
    conn = SolidModelComponent(xao, SemanticMeta(:conn); name="conn")
    g = SchematicGraph("smcn")
    sp1 = add_node!(g, Spacer(; p1=Point(100μm, 0μm)))
    sp2 = fuse!(g, sp1 => :p1_east, Spacer(; p1=Point(100μm, 0μm)) => :p0_west)
    ids = [
        fuse!(g, sp1 => :p0_west, conn => :east).id,
        fuse!(g, sp1 => :p1_east, conn => :west).id,
        fuse!(g, sp2 => :p1_east, conn => :west).id
    ]
    sch = plan(g; log_dir=nothing)
    check!(sch)
    tech = ProcessTechnology((; conn=GDSMeta()), (; height=(; conn=0μm)))
    sm = SolidModel("smcn"; overwrite=true)
    render!(sm, sch, SolidModelTarget(tech))

    @test allunique(ids)
    for id in ids
        # One solid named after the node, and the file's groups prefixed with the node id.
        @test hasgroup(sm, id, 3)
        @test length(dimtags(sm[id, 3])) == 1
        @test hasgroup(sm, "$(id)_body", 3)
        @test hasgroup(sm, "$(id)_pin", 2)
        @test length(dimtags(sm["$(id)_pin", 2])) == 1
        @test dimtags(sm["$(id)_body", 3]) == dimtags(sm[id, 3])
    end
    # Each node got its own solid, at its own position.
    vols = [only(dimtags(sm[id, 3])) for id in ids]
    @test allunique(vols)
    xs = [gmsh.model.occ.getCenterOfMass(v...)[1] for v in vols]
    @test sort(round.(xs)) == [0.0, 100.0, 200.0]   # the cube is centred on its hook point

    # Inside a composite, the node id is prefixed with the parent's id, so two instances of
    # the same composite still give distinct groups.
    reset_uniquename!()
    inner = SchematicGraph("inner")
    sp = add_node!(inner, Spacer(; p1=Point(10μm, 0μm)))
    fuse!(inner, sp => :p1_east, conn => :west)
    comp = BasicCompositeComponent(inner)
    gc = SchematicGraph("smcn_composite")
    s0 = add_node!(gc, Spacer(; p1=Point(100μm, 0μm)))
    parents = [
        fuse!(gc, s0 => :p0_west, comp => :_1_p0_west).id,
        fuse!(gc, s0 => :p1_east, comp => :_1_p0_west).id
    ]
    schc = plan(gc; log_dir=nothing)
    check!(schc)
    smc = SolidModel("smcn_composite"; overwrite=true)
    render!(smc, schc, SolidModelTarget(tech))
    child = only(n.id for n in nodes(inner) if component(n) isa SolidModelComponent)
    cids = ["$(p).$(child)" for p in parents]
    @test allunique(cids)
    for id in cids
        @test hasgroup(smc, id, 3)
        @test hasgroup(smc, "$(id)_body", 3)
    end
    cvols = [only(dimtags(smc[id, 3])) for id in cids]
    @test allunique(cvols)
end

@testitem "SolidModelComponent placement: rotation and layer z" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent, Spacer, transformation
    import DeviceLayout.SolidModels: gmsh, dimtags
    import DeviceLayout: SemanticMeta, GDSMeta, Point, rotation, getx, gety

    # ASYMMETRIC CAD: a 40×10×10 μm bar from the origin. Its centroid (20,5,5) is not at the
    # component origin, so a rotation actually moves it — orientation is observable (unlike a
    # centred cube). z-centroid is 5.
    _tmp = SolidModel("smcr_author"; overwrite=true)
    brep = joinpath(tdir, "smcr_bar.brep")
    gmsh.model.add("smcr_auth")
    gmsh.model.occ.addBox(0, 0, 0, 40, 10, 10)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    # Mate so the transform includes a real rotation: component :east hook (dir 0°) onto the
    # spacer's :p1_north hook (at (100,50), dir 90°) → component rotated (hooks point opposite).
    reset_uniquename!()
    g = SchematicGraph("smcr")
    sp = add_node!(g, Spacer(; p1=Point(100μm, 50μm)))
    smc_node = fuse!(
        g,
        sp => :p1_north,
        SolidModelComponent(brep, SemanticMeta(:comp_layer); name="cad") => :east
    )
    sch = plan(g; log_dir=nothing)
    check!(sch)

    # comp_layer sits at a NONZERO height (100 μm) in the process stack → tests meta→layer_z→z.
    tech = ProcessTechnology((; comp_layer=GDSMeta()), (; height=(; comp_layer=100μm)))
    sm = SolidModel("smcr"; overwrite=true)
    @test_nowarn render!(sm, sch, SolidModelTarget(tech))

    trans = transformation(sch, smc_node)
    @test rotation(trans) ≈ -90°

    # The imported solid's centroid must equal the solved transform applied to the CAD centroid
    # (xy) and the CAD z-centroid lifted by the layer height (z). Asymmetric solid ⇒ this fails
    # if the rotation is wrong; nonzero layer height ⇒ this fails if the z-lift is wrong.
    exp_xy = trans(Point(20μm, 5μm))
    grp = only(
        filter(
            n -> startswith(n, "cad"),
            collect(keys(SchematicDrivenLayout.SolidModels.dimgroupdict(sm, 3)))
        )
    )
    c = gmsh.model.occ.getCenterOfMass(dimtags(sm[grp, 3])[1]...)
    @test c[1] ≈ ustrip(μm, getx(exp_xy)) atol = 1e-6
    @test c[2] ≈ ustrip(μm, gety(exp_xy)) atol = 1e-6
    @test c[3] ≈ 105.0 atol = 1e-6                 # CAD z-centroid (5) + layer_z (100 μm)

    gmsh.model.set_current("smcr")
    gmsh.model.mesh.generate(3)
    _, et, _ = gmsh.model.mesh.getElements(3)
    @test sum(length, et) > 0
end

@testitem "SolidModelComponent honours user-supplied hooks" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent, Spacer, transformation
    import DeviceLayout.SolidModels: gmsh, dimtags
    import DeviceLayout: SemanticMeta, GDSMeta, Point, PointHook, rotation

    # Use a centred cube so its centroid tracks the component origin.
    _tmp = SolidModel("smch_author"; overwrite=true)
    brep = joinpath(tdir, "smch_cube.brep")
    gmsh.model.add("smch_auth")
    gmsh.model.occ.addBox(-5, -5, -5, 10, 10, 10)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    # Place the mate hook 10 μm away from the CAD origin, pointing west.
    reset_uniquename!()
    g = SchematicGraph("smch")
    sp = add_node!(g, Spacer(; p1=Point(100μm, 50μm)))
    smc = SolidModelComponent(
        brep,
        SemanticMeta(:chip_outline);
        name="cad",
        hooks=(; mount=PointHook(10μm, 0μm, 180°))
    )
    smc_node = fuse!(g, sp => :p1_east, smc => :mount)
    sch = plan(g; log_dir=nothing)
    check!(sch)

    tech = ProcessTechnology((; chip_outline=GDSMeta()), (;))
    sm = SolidModel("smch"; overwrite=true)
    @test_nowarn render!(sm, sch, SolidModelTarget(tech))

    trans = transformation(sch, smc_node)
    @test rotation(trans) ≈ 0° # West-to-east mating requires no rotation.
    # Mating (10,0) to (100,50) places the CAD origin, and therefore its centroid, at (90,50).
    grp = only(
        filter(
            n -> startswith(n, "cad"),
            collect(keys(SchematicDrivenLayout.SolidModels.dimgroupdict(sm, 3)))
        )
    )
    c = gmsh.model.occ.getCenterOfMass(dimtags(sm[grp, 3])[1]...)
    @test c[1] ≈ 90.0 atol = 1e-6
    @test c[2] ≈ 50.0 atol = 1e-6
end

@testitem "SolidModelComponent hook-mated, conformal in vacuum, exclusive material" setup =
    [CommonTestSetup, QuietGmshSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent, Spacer, find_components
    import DeviceLayout.SolidModels: gmsh, dimtags, apply_precedence
    import DeviceLayout: SemanticMeta, GDSMeta, Point

    _tmp = SolidModel("smcv_author"; overwrite=true)
    brep = joinpath(tdir, "smcv_cube.brep")
    gmsh.model.add("smcv_auth")
    gmsh.model.occ.addBox(-20, -20, -20, 40, 40, 40)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

    tech = ProcessTechnology(
        (; vacuum=GDSMeta(), cad=GDSMeta(2)),
        (; height=(; vacuum=-50μm, cad=0μm), thickness=(; vacuum=100μm))
    )
    function planned()
        reset_uniquename!()
        g = SchematicGraph("smcv")
        sp = add_node!(g, Spacer(; p1=Point(10μm, 0μm)))
        fuse!(
            g,
            sp => :p1_east,
            SolidModelComponent(brep, SemanticMeta(:cad); name="cad") => :west
        )
        sch = plan(g; log_dir=nothing)
        check!(sch)
        render!(
            sch.coordinate_system,
            centered(Rectangle(100μm, 100μm)),
            SemanticMeta(:vacuum)
        )
        check!(sch)
        return sch, sch.graph[only(find_components(SolidModelComponent, sch))].id
    end
    precedence(cad_group) = apply_precedence([(cad_group, 3), ("vacuum_extrusion", 3)])

    # `dimtags` queries gmsh's current model, so each check runs right after its render.
    function check_model(sm, cad_group)
        gmsh.model.set_current(SolidModels.name(sm))
        vol(g) = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(sm[g, 3]))
        faceset(g) = Set(
            abs(t) for
            (d, t) in gmsh.model.getBoundary(dimtags(sm[g, 3]), false, false, false)
        )
        vtags(g) = Set((d, t) for (d, t) in dimtags(sm[g, 3]))

        @testset "pose" begin
            c = gmsh.model.occ.getCenterOfMass(dimtags(sm[cad_group, 3])[1]...)
            @test c[1] ≈ 10.0 atol = 1e-6
            @test c[2] ≈ 0.0 atol = 1e-6
            @test c[3] ≈ 0.0 atol = 1e-6
        end
        @testset "conformal + exclusive material" begin
            @test !isempty(intersect(faceset(cad_group), faceset("vacuum_extrusion")))
            @test isempty(intersect(vtags(cad_group), vtags("vacuum_extrusion")))
            @test vol(cad_group) ≈ 64000.0 atol = 1e-3
            @test vol("vacuum_extrusion") ≈ 1e6 - 64000.0 atol = 1e-3
        end
        @testset "meshes" begin
            gmsh.model.mesh.generate(3)
            _, et, _ = gmsh.model.mesh.getElements(3)
            @test sum(length, et) > 0
        end
    end

    @testset "global fragment, precedence from the target" begin
        sch, cad_group = planned()
        target = SolidModelTarget(tech; post_fragment_ops=precedence(cad_group))
        sm = SolidModel("smcv"; overwrite=true)
        @test_nowarn render!(sm, sch, target)
        check_model(sm, cad_group)
    end

    @testset "near fragment, precedence from the call" begin
        # The import and `fragment_near!` are themselves post-fragment operations, so this
        # fails if the user's operations replace the component's instead of following them.
        sch, cad_group = planned()
        sm = SolidModel("smcv_near"; overwrite=true)
        @test_nowarn render!(
            sm,
            sch,
            SolidModelTarget(tech);
            component_fragment=:near,
            post_fragment_ops=precedence(cad_group)
        )
        check_model(sm, cad_group)
    end
end
