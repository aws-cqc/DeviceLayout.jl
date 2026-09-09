using PrecompileTools

@static if unit_preference == "NoUnits"
    @setup_workload begin
        @compile_workload begin
            cs = CoordinateSystem("test")
            r = Polygons.Rounded(simple_tee(1, 10), 1)
            place!(cs, r, :test)
        end
    end
else
    @setup_workload begin
        using .SchematicDrivenLayout
        using .SchematicDrivenLayout.ExamplePDK
        using .SchematicDrivenLayout.ExamplePDK.LayerVocabulary
        using .ExamplePDK.ChipTemplates,
            .ExamplePDK.Transmons, .ExamplePDK.ReadoutResonators
        import FileIO: File, @format_str, add_format
        # FileIO formats are normally registered in `__init__`, which has not run yet.
        # Registrations made here live in FileIO's global registry, which is not part
        # of this package's image, so `__init__` still registers them on load.
        add_format(
            format"GDS",
            UInt8[0x00, 0x06, 0x00, 0x02],
            ".gds",
            [:DeviceLayout => UUID("ebf59a4a-04ec-49d7-8cd4-c9382ceb8e85")]
        )
        # Clipper handles are normally created in `__init__`, which has not run yet;
        # `__init__` replaces these when the package is loaded.
        global _clip = Ref(Clipper.Clip())
        global _coffset = Ref(Clipper.ClipperOffset())
        outdir = mktempdir()
        @compile_workload begin
            cs = CoordinateSystem("test", nm)
            cs2 = CoordinateSystem("attachment", nm)
            r = Polygons.Rounded(simple_tee(1μm, 10μm), 1μm)
            place!(cs2, r, :test)

            pa = Path(nm)
            straight!(pa, 100μm, Paths.SimpleCPW(10μm, 6μm))
            turn!(pa, 45°, 100μm)
            attach!(pa, sref(cs2), pathlength(pa[end]))
            pa.metadata = SemanticMeta(:test)

            addref!(cs, sref(pa, rot=45°))
            c = Cell(cs)

            # Schematic-driven layout: chip, launchers, transmon, tapped resonator, and one
            # route per built-in rule, rendered to GDS and to an image.
            reset_uniquename!()
            g = SchematicGraph("precompile")
            chip = add_node!(g, ExampleChip(; port_lr_count=2, port_tb_count=2))
            l1 = fuse!(g, chip => :port_4, example_launcher((:readout, 1)) => :p0)
            l2 = fuse!(g, chip => :port_8, example_launcher((:xy, 1)) => :p0)
            l3 = fuse!(g, chip => :port_6, example_launcher((:z, 1)) => :p0)
            tr = add_node!(g, ExampleRectangleTransmon())
            res = fuse!(
                g,
                tr => :readout,
                ExampleTappedHairpin(; straight_length=1.25mm) => :tap
            )
            # Attach a component at a point along a path node
            pa2 = Path(nm; name="pa2", metadata=METAL_NEGATIVE)
            straight!(pa2, 1mm, Paths.CPW(10μm, 6μm))
            pa2_node = add_node!(g, pa2)
            attach!(
                g,
                pa2_node,
                ExampleTappedHairpin(; straight_length=1.25mm, name="res2") => :tap,
                0.5mm;
                i=1,
                location=1
            )
            fuse!(g, chip => :port_3, pa2_node => :p0)
            route!(
                g,
                Paths.StraightAnd90(0.2mm),
                res => :p0,
                l1 => :p1,
                Paths.CPW(10μm, 6μm),
                METAL_NEGATIVE;
                name="r1",
                waypoints=[Point(2mm, -0.3mm)],
                global_waypoints=true
            )
            route!(
                g,
                Paths.StraightAnd45(0.1mm),
                tr => :xy,
                l2 => :p1,
                Paths.CPW(4μm, 2μm),
                METAL_NEGATIVE;
                name="r2"
            )
            route!(
                g,
                Paths.BSplineRouting(),
                tr => :z,
                l3 => :p1,
                Paths.CPW(4μm, 2μm),
                METAL_NEGATIVE;
                name="r3"
            )
            sch = plan(g; log_dir=nothing)
            check!(sch)
            cell = Cell("precompile", nm)
            render!(cell, sch, ExamplePDK.L1_TARGET)
            save(File{format"GDS"}(joinpath(outdir, "precompile.gds")), cell)
            flat = flatten(cell)
            bounds(sch, tr)
            save(File{format"PNG"}(joinpath(outdir, "precompile.png")), flat; width=200)
            b = bounds(sch, tr)
            colors = Dict(GDSMeta(1, 2) => (0.1, 0.1, 0.6, 1.0))
            save(
                File{format"PNG"}(joinpath(outdir, "precompile_zoom.png")),
                flat;
                width=100,
                bbox=Rectangle(b.ll, b.ur),
                layercolors=colors
            )
        end
        # Don't bake stale Clipper handles into the package image
        global _clip = nothing
        global _coffset = nothing
    end
end
