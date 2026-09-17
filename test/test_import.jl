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

@testitem "SolidModel CAD import from .xao with physical groups" setup = [CommonTestSetup] begin
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
        @test unique(first.(new)) == Int32[3]    # highest_dim_only keeps the two solids
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

        sd = SolidModel("xao_discard"; overwrite=true)
        import_solid!(sd, xao; group_map=nothing)
        @test isempty(dimgroupdict(sd, 2))
        @test collect(keys(dimgroupdict(sd, 3))) == ["imported"]
    end

    @testset "highest_dim_only=false returns and groups every dimension" begin
        sm = SolidModel("xao_alldims"; overwrite=true)
        new = import_solid!(sm, xao; highest_dim_only=false, groupname="all")
        @test Set(first.(new)) == Set(Int32[0, 1, 2, 3])
        @test hasgroup(sm, "all", 2) && hasgroup(sm, "all", 3)
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

@testitem "SolidModelComponent renders + meshes in a schematic" setup = [CommonTestSetup] begin
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
    add_node!(g, smc)
    sch = plan(g; log_dir=nothing)
    check!(sch)

    tech = ProcessTechnology((; chip_outline=GDSMeta()), (;))
    target = SolidModelTarget(tech)
    sm = SolidModel("smc"; overwrite=true)
    @test_nowarn render!(sm, sch, target)

    @testset "component imported as its own physical group" begin
        @test hasgroup(sm, "cad_1", 3)
        vol = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(sm["cad_1", 3]))
        @test vol ≈ 1000.0 atol = 1e-6
    end

    @testset "meshes" begin
        gmsh.model.set_current("smc")
        gmsh.model.mesh.generate(3)
        _, et, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, et) > 0
    end
end

@testitem "SolidModelComponent lands at its hook-mated pose" setup = [CommonTestSetup] begin
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

@testitem "SolidModelComponent fuses with schematic geometry" setup = [CommonTestSetup] begin
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
    add_node!(g, SolidModelComponent(brep, SemanticMeta(:chip_outline); name="cad"))
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
        @test hasgroup(sm, "cad_1", 3)                       # imported CAD group
        @test hasgroup(sm, "chip_outline_L1_extrusion", 3)   # extruded substrate
        # The cube rests on the substrate top → the fragment pass makes a shared interface face.
        @test !isempty(intersect(faceset("cad_1"), faceset("chip_outline_L1_extrusion")))
    end

    @testset "meshes" begin
        gmsh.model.set_current("smcf")
        gmsh.model.mesh.generate(3)
        _, et, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, et) > 0
    end
end

@testitem "SolidModelComponent placement: rotation and layer z" setup = [CommonTestSetup] begin
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

@testitem "SolidModelComponent honours user-supplied hooks" setup = [CommonTestSetup] begin
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

@testitem "partition_material_groups! enforces material precedence" setup =
    [CommonTestSetup] begin
    using DeviceLayout.SolidModels
    import DeviceLayout.SolidModels: gmsh, dimtags, partition_material_groups!

    # Model the overlapping memberships left by fragmentation.
    sm = SolidModel("matpart"; overwrite=true)
    v = [gmsh.model.occ.addBox(20i, 0, 0, 10, 10, 10) for i = 0:3]
    gmsh.model.occ.synchronize()
    sm["chip"] = [(3, v[1]), (3, v[2])]
    sm["vacuum"] = [(3, v[2]), (3, v[3]), (3, v[4])]
    sm["annotation"] = [(3, v[4])]

    tagset(g) = Set(Int(t) for (d, t) in dimtags(sm[g, 3]))
    chip_before = tagset("chip")
    vacuum_before = tagset("vacuum")
    @test_throws ArgumentError partition_material_groups!(
        sm,
        [("chip", 3), ("missing", 3), ("vacuum", 3)]
    )
    @test_throws ArgumentError partition_material_groups!(
        sm,
        [("chip", 3), ("chip", 3), ("vacuum", 3)]
    )
    @test tagset("chip") == chip_before
    @test tagset("vacuum") == vacuum_before

    partition_material_groups!(sm, [("chip", 3), ("vacuum", 3)])
    @test tagset("chip") == Set(Int.(v[1:2]))
    @test tagset("vacuum") == Set(Int.(v[3:4]))
    @test isempty(intersect(tagset("chip"), tagset("vacuum"))) # mutually exclusive
    @test tagset("annotation") == Set([Int(v[4])])
end

@testitem "SolidModelComponent hook-mated, fused in vacuum, exclusive material" setup =
    [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import DeviceLayout.SchematicDrivenLayout: SolidModelComponent, Spacer, find_components
    import DeviceLayout.SolidModels: gmsh, dimtags
    import DeviceLayout: SemanticMeta, GDSMeta, Point

    _tmp = SolidModel("smcv_author"; overwrite=true)
    brep = joinpath(tdir, "smcv_cube.brep")
    gmsh.model.add("smcv_auth")
    gmsh.model.occ.addBox(-20, -20, -20, 40, 40, 40)
    gmsh.model.occ.synchronize()
    gmsh.write(brep)
    gmsh.model.remove()

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
    render!(sch.coordinate_system, centered(Rectangle(100μm, 100μm)), SemanticMeta(:vacuum))
    check!(sch)

    cad_group = "cad_$(only(find_components(SolidModelComponent, sch)))"
    tech = ProcessTechnology(
        (; vacuum=GDSMeta(), cad=GDSMeta(2)),
        (; height=(; vacuum=-50μm, cad=0μm), thickness=(; vacuum=100μm))
    )
    target = SolidModelTarget(
        tech;
        material_precedence=[(cad_group, 3), ("vacuum_extrusion", 3)]
    )
    sm = SolidModel("smcv"; overwrite=true)
    @test_nowarn render!(sm, sch, target)

    vol(g) = sum(gmsh.model.occ.getMass(d, t) for (d, t) in dimtags(sm[g, 3]))
    faceset(g) = Set(
        abs(t) for (d, t) in gmsh.model.getBoundary(dimtags(sm[g, 3]), false, false, false)
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
        gmsh.model.set_current("smcv")
        gmsh.model.mesh.generate(3)
        _, et, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, et) > 0
    end
end

@testitem "targeted_fuse! bounding-box-pruned fusion" setup = [CommonTestSetup] begin
    using DeviceLayout.SolidModels
    import DeviceLayout.SolidModels:
        SolidModel,
        dimtags,
        gmsh,
        targeted_fuse!,
        _warn_bbox_overlap_no_boundary,
        _fragment_three_pass!,
        GmshNative
    using Unitful: μm

    # A fake "package": two pads (tops at z=10) with a chip resting on them, plus two far-away
    # boxes the chip never touches. Mirrors a package+chip stitch at (tiny) scale.
    function build_package(nm)
        sm = SolidModel(nm; overwrite=true)
        gmsh.model.set_current(nm)
        occ = gmsh.model.occ
        pa = occ.addBox(-40, -40, 0, 30, 30, 10)
        pb = occ.addBox(10, 10, 0, 30, 30, 10)
        ch = occ.addBox(-40, -40, 10, 80, 80, 20)   # rests on both pad tops (z=10)
        f1 = occ.addBox(500, 500, 0, 10, 10, 10)
        f2 = occ.addBox(-500, -500, 0, 10, 10, 10)
        occ.synchronize()
        sm["pad_a"] = [(Int32(3), Int32(pa))]
        sm["pad_b"] = [(Int32(3), Int32(pb))]
        sm["chip"]  = [(Int32(3), Int32(ch))]
        sm["far1"]  = [(Int32(3), Int32(f1))]
        sm["far2"]  = [(Int32(3), Int32(f2))]
        return sm
    end
    boundary_tags(dts) =
        Set(abs(t) for (d, t) in gmsh.model.getBoundary(dts, false, false, false))
    faceset(sm, grp) = boundary_tags(dimtags(sm[grp, 3]))
    shared(sm, a, b) = length(intersect(faceset(sm, a), faceset(sm, b)))
    vtags(sm, grp) = Set(t for (d, t) in dimtags(sm[grp, 3]))
    # Faces on no volume boundary: orphans left by fragmentation, meshed as detached triangles.
    function orphan_faces(sm)
        gmsh.model.set_current(SolidModels.name(sm))
        vf = boundary_tags(gmsh.model.getEntities(3))
        return [t for (_, t) in gmsh.model.getEntities(2) if !(t in vf)]
    end
    function nentities(sm, dim)
        gmsh.model.set_current(SolidModels.name(sm))
        return length(gmsh.model.getEntities(dim))
    end
    # Tag the chip's bottom (z=10) face before fusing, like a Palace boundary-condition surface.
    function tag_chip_bottom!(sm)
        ch = only(dimtags(sm["chip", 3]))
        function at_z10(dt)
            bb = gmsh.model.getBoundingBox(dt[1], abs(dt[2]))   # (xmin, ymin, zmin, xmax, ymax, zmax)
            return bb[3] ≈ 10.0 && bb[6] ≈ 10.0
        end
        faces =
            [(d, abs(t)) for (d, t) in gmsh.model.getBoundary([ch], false, false, false)]
        sm["chip_bottom"] = filter(at_z10, faces)
        return nothing
    end
    const BOX = (-41μm, -41μm, -1μm, 41μm, 41μm, 31μm)   # chip + both pads, not the far boxes

    @testset "targeted: fuses neighbors, leaves the rest untouched" begin
        sm = build_package("tf_pruned")
        far1_before, far2_before = vtags(sm, "far1"), vtags(sm, "far2")
        targeted_fuse!(sm, "chip"; bbox=BOX)
        @test shared(sm, "chip", "pad_a") == 1      # conformal interface formed
        @test shared(sm, "chip", "pad_b") == 1
        @test shared(sm, "chip", "far1") == 0       # never touched the far boxes
        @test vtags(sm, "far1") == far1_before      # far entities not re-fragmented
        @test vtags(sm, "far2") == far2_before
        gmsh.model.set_current("tf_pruned")
        gmsh.model.mesh.generate(3)
        _, et, _ = gmsh.model.mesh.getElements(3)
        @test sum(length, et) > 0
        @test minimum(gmsh.model.mesh.getElementQualities(reduce(vcat, et))) > 0.1
    end

    @testset "targeted matches global: no orphan entities, dim-2 groups land on real faces" begin
        smg = build_package("tf_global")
        tag_chip_bottom!(smg)
        targeted_fuse!(smg, "chip"; bbox=nothing)   # nothing → global fragment
        @test shared(smg, "chip", "pad_a") == 1
        @test shared(smg, "chip", "pad_b") == 1
        @test isempty(orphan_faces(smg))
        nf_global, nc_global = nentities(smg, 2), nentities(smg, 1)

        for (nm, kw) in (("tf_auto_cmp", (;)), ("tf_box_cmp", (; bbox=BOX)))
            smt = build_package(nm)
            tag_chip_bottom!(smt)
            targeted_fuse!(smt, "chip"; warn=false, kw...)
            # Same entity counts as the global pass and nothing floating.
            @test nentities(smt, 2) == nf_global
            @test nentities(smt, 1) == nc_global
            @test isempty(orphan_faces(smt))
            # The pre-tagged bottom face was split into three pieces (pad_a contact, pad_b
            # contact, remainder), every one of which is a genuine boundary face of the chip.
            cb = Set(t for (_, t) in dimtags(smt["chip_bottom", 2]))
            @test length(cb) == 3
            @test cb ⊆ faceset(smt, "chip")
        end
    end

    @testset "free-standing sheet inside the region is fragmented too" begin
        # A zero-thickness sheet (like a lumped port) in the chip bottom plane, on no volume.
        function with_sheet(nm)
            sm = build_package(nm)
            gmsh.model.set_current(nm)
            sheet = gmsh.model.occ.addRectangle(-40, -40, 10, 80, 80)
            gmsh.model.occ.synchronize()
            sm["sheet"] = [(Int32(2), Int32(sheet))]
            return sm
        end
        smg = with_sheet("tf_sheet_global")
        targeted_fuse!(smg, "chip"; bbox=nothing)
        n_global = length(dimtags(smg["sheet", 2]))
        @test n_global == 3

        smt = with_sheet("tf_sheet_targeted")
        targeted_fuse!(smt, "chip"; warn=false)
        sheet_faces = Set(t for (_, t) in dimtags(smt["sheet", 2]))
        @test length(sheet_faces) == n_global
        @test sheet_faces ⊆ faceset(smt, "chip")   # every piece is now a chip boundary face
        @test isempty(orphan_faces(smt))
    end

    @testset "seam warning" begin
        sm = SolidModel("tf_warn"; overwrite=true)
        gmsh.model.set_current("tf_warn")
        occ = gmsh.model.occ
        # Two boxes touching only along the edge x = y = 30. Once fragmented they are perfectly
        # conformal (they share that edge) although their bounding boxes still overlap.
        e1 = occ.addBox(20, 20, 0, 10, 10, 10)
        e2 = occ.addBox(30, 30, 0, 10, 10, 10)
        occ.synchronize()
        sm["e1"] = [(Int32(3), Int32(e1))]
        sm["e2"] = [(Int32(3), Int32(e2))]
        _fragment_three_pass!(sm)
        # Added after the fragment: two interpenetrating boxes that overlap but share no
        # topological entity → a genuine non-conformal seam.
        b1 = occ.addBox(0, 0, 0, 10, 10, 10)
        b2 = occ.addBox(5, 0, 0, 10, 10, 10)
        occ.synchronize()
        @test_logs (:warn,) _warn_bbox_overlap_no_boundary(
            [(Int32(3), Int32(b1)), (Int32(3), Int32(b2))],
            0.0
        )
        @test_logs _warn_bbox_overlap_no_boundary(
            vcat(dimtags(sm["e1", 3]), dimtags(sm["e2", 3])),
            0.0
        )
    end

    # A 1D physical group on an edge of `vol_group`, via volume → faces → curves
    # (getBoundary recursive=true would jump straight to points).
    function tag_edge!(sm, vol_group, edge_group)
        pa = [(Int32(3), only(vtags(sm, vol_group)))]
        faces = gmsh.model.getBoundary(pa, false, false, false)
        curves = gmsh.model.getBoundary(faces, false, false, false)
        sm[edge_group] = [(Int32(1), abs(first(curves)[2]))]
        return nothing
    end

    @testset "lower-dim groups: far preserved, neighborhood no worse than global" begin
        # (a) A 1D group far from the box (on far1) is left exactly untouched by targeted fusion.
        sm = build_package("tf_faredge")
        tag_edge!(sm, "far1", "far_edge")
        before = Set(t for (d, t) in dimtags(sm["far_edge", 1]))
        targeted_fuse!(sm, "chip"; bbox=BOX)
        @test Set(t for (d, t) in dimtags(sm["far_edge", 1])) == before

        # (b) For an edge inside the fused neighborhood, targeted is no worse than global.
        # Fragmentation can retag/drop a dim-1 group on a fused boundary under either path.
        # `dimtags` queries gmsh's current model, so read each result before building the next.
        sg = build_package("tf_edge_global")
        tag_edge!(sg, "pad_a", "edge_grp")
        targeted_fuse!(sg, "chip"; bbox=nothing)
        n_global = length(dimtags(sg["edge_grp", 1]))
        st = build_package("tf_edge_targeted")
        tag_edge!(st, "pad_a", "edge_grp")
        targeted_fuse!(st, "chip"; bbox=BOX)
        @test length(dimtags(st["edge_grp", 1])) == n_global
    end

    @testset "validation and API" begin
        sm = build_package("tf_valid")
        # Missing group must error (not silently fall back to a global fragment).
        @test_throws ArgumentError targeted_fuse!(sm, "nope"; bbox=nothing)
        # Non-OpenCascade kernel is rejected.
        smn = SolidModel("tf_native", GmshNative(); overwrite=true)
        @test_throws ArgumentError targeted_fuse!(smn, "chip")
        # Symbol group names are accepted and behave like the String form.
        sm2 = build_package("tf_symbol")
        @test targeted_fuse!(sm2, :chip; bbox=BOX) == dimtags(sm2["chip", 3])
        # Targeted selection is the default.
        sm3 = build_package("tf_auto")
        far_before = vtags(sm3, "far1")
        targeted_fuse!(sm3, "chip"; warn=false)
        @test shared(sm3, "chip", "pad_a") == 1
        @test shared(sm3, "chip", "pad_b") == 1
        @test vtags(sm3, "far1") == far_before

        gmsh.model.set_current("tf_valid")
        @test_throws ArgumentError targeted_fuse!(sm, "chip"; bbox=:invalid)
        @test_throws ArgumentError targeted_fuse!(sm, "chip"; bbox=(0μm, 1μm))
        @test_throws ArgumentError targeted_fuse!(
            sm,
            "chip";
            bbox=(1μm, 0μm, 0μm, 0μm, 1μm, 1μm)
        )
        # An explicit box that misses the object entirely is a user error, not a no-op.
        @test_throws ArgumentError targeted_fuse!(
            sm,
            "chip";
            bbox=(100μm, 100μm, 100μm, 110μm, 110μm, 110μm)
        )
        # delta is validated regardless of which bbox branch is taken.
        @test_throws ArgumentError targeted_fuse!(sm, "chip"; delta=-1μm)
        @test_throws ArgumentError targeted_fuse!(sm, "chip"; delta=-1μm, bbox=nothing)
        @test_throws ArgumentError targeted_fuse!(sm, "chip"; delta=-1μm, bbox=BOX)
        # A group whose entities were consumed is caught rather than returning [].
        gmsh.model.occ.remove(dimtags(sm["chip", 3]))
        gmsh.model.occ.synchronize()
        @test_throws ArgumentError targeted_fuse!(sm, "chip")
    end

    @testset "no neighboring volumes warns and is a no-op" begin
        sm = SolidModel("tf_isolated"; overwrite=true)
        gmsh.model.set_current("tf_isolated")
        vol = gmsh.model.occ.addBox(0, 0, 0, 10, 10, 10)
        gmsh.model.occ.synchronize()
        sm["chip"] = [(Int32(3), Int32(vol))]
        before = dimtags(sm["chip", 3])
        @test (@test_logs (:warn,) targeted_fuse!(sm, "chip")) == before
        @test (@test_logs targeted_fuse!(sm, "chip"; warn=false)) == before
        @test dimtags(sm["chip", 3]) == before
    end
end
