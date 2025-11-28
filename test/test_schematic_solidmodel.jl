@testitem "Schematic + SolidModel" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout: AbstractComponent

    reset_uniquename!()
    BASE_NEGATIVE = SemanticMeta(:base_negative)

    ## Test components for checking SolidModel rendering.
    using LinearAlgebra

    # A lattice of squares
    @compdef struct SquareLattice <: AbstractComponent{typeof(1.0nm)}
        name = "square_lattice"
        d = [120μm, 40μm, 20μm, 10μm]
        δ = 30μm
        rounded = false
    end

    function base_shape(r::SquareLattice)
        (; d, δ) = r

        r1 = centered(Rectangle(d[1], d[1]))
        r2 = centered(Rectangle(d[2], d[2]))
        r3 = centered(Rectangle(d[3], d[3]))
        r4 = centered(Rectangle(d[4], d[4]))

        cc =
            [r2 + Point(+δ, +δ); r2 + Point(-δ, +δ); r2 + Point(+δ, -δ); r2 + Point(-δ, -δ)]
        u = difference2d(r1, cc)

        ss = difference2d(r3, r4)
        cc2 =
            [ss + Point(+δ, +δ); ss + Point(-δ, +δ); ss + Point(+δ, -δ); ss + Point(-δ, -δ)]

        return union2d(u, cc2)
    end

    function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, r::SquareLattice)
        !r.rounded && return render!(cs, base_shape(r), BASE_NEGATIVE)

        d = StyleDict()
        u = base_shape(r)

        d[1] = Polygons.Rounded(r.d[1] / 4)
        d[1, 1, 1, 1] = Polygons.Rounded(r.d[4] / 4, p0=u[1, 1, 1, 1].contour[[4]])
        d[1, 2, 1, 1] = Polygons.Rounded(r.d[4] / 4, p0=u[1, 2, 1, 1].contour[[1]])
        d[1, 3, 1, 1] = Polygons.Rounded(r.d[4] / 4, p0=u[1, 3, 1, 1].contour[[3]])
        d[1, 4, 1, 1] = Polygons.Rounded(r.d[4] / 4, p0=u[1, 4, 1, 1].contour[[2]])

        d[1, 1] = Polygons.Rounded(r.d[2] / 4, p0=u[1, 1].contour[[4]])
        d[1, 2] = Polygons.Rounded(r.d[2] / 4, p0=u[1, 2].contour[[1]])
        d[1, 3] = Polygons.Rounded(r.d[2] / 4, p0=u[1, 3].contour[[1]])
        d[1, 4] = Polygons.Rounded(r.d[2] / 4, p0=u[1, 4].contour[[4]])
        return render!(cs, DeviceLayout.StyledEntity(u, d), BASE_NEGATIVE)
    end

    @compdef struct NestedSquares <: AbstractComponent{typeof(1.0nm)}
        name = "squares"
        d = [1mm, 0.75mm, 0.5mm, 0.25mm]
        rounded = false
    end

    function base_shape(r::NestedSquares)
        (; d) = r
        r1 = difference2d(centered(Rectangle(d[1], d[1])), centered(Rectangle(d[2], d[2])))
        r2 = difference2d(centered(Rectangle(d[3], d[3])), centered(Rectangle(d[4], d[4])))
        return union2d(r1, r2)
    end

    function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, r::NestedSquares)
        !r.rounded && return render!(cs, base_shape(r), BASE_NEGATIVE)
        p = base_shape(r)
        u = Polygons.Rounded(r.d[end] / 4, p0=p[1].contour[[1, 3]])(p)
        return render!(cs, u, BASE_NEGATIVE)
    end

    @compdef struct TiledPolygons <: AbstractComponent{typeof(1.0nm)}
        name = "poly"
        p = convert(Polygon, Rectangle(20μm, 20μm))
        δ = 50μm
        n = 2
        rounded = false
    end

    function base_shape(s::TiledPolygons)
        (; p, δ, n) = s
        return union2d([p + Point(i * δ, zero(δ)) for i ∈ 0:(n - 1)])
    end

    function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, r::TiledPolygons)
        !r.rounded && return render!(cs, base_shape(r), BASE_NEGATIVE)
        p = base_shape(r)
        u = Polygons.Rounded(
            norm(upperright(r.p) - lowerleft(r.p)) / 5,
            p0=p[1].contour[[1]]
        )(
            p
        )
        return render!(cs, u, BASE_NEGATIVE)
    end

    """
    test_component(x, clip_area, mesh=false, gui=false)

    Helper for rendering a component to a chip and testing for no warnings
    x -- component to be tested
    chip_option -- flag for which chip assembly option to use
    1 -- The simulated area and chip area are the same
    2 -- The simulated area is larger
    3 -- The simulated area is smaller
    gui -- whether or not to display the gmsh gui after rendering to the model
    """
    function test_component(component, clip_area, mesh=false, gui=false)
        g = SchematicGraph("test_component")
        add_node!(g, component)
        floorplan = plan(g; log_dir=nothing)

        if clip_area == 1
            # identical area - chip render first
            chip_area = union2d(halo(bounds(floorplan), 100μm))
            sim_area = chip_area
        elseif clip_area == 2
            # sim area larger
            chip_area = union2d(halo(bounds(floorplan), 100μm))
            sim_area = union2d(halo(chip_area, 100μm))
        elseif clip_area == 3
            # chip area larger
            sim_area = union2d(halo(bounds(floorplan), 100μm))
            chip_area = union2d(halo(sim_area, 100μm))
        end
        render!(floorplan.coordinate_system, chip_area, SemanticMeta(:chip_outline))
        render!(
            floorplan.coordinate_system,
            chip_area,
            SemanticMeta(:chip_outline, level=2)
        )
        render!(
            floorplan.coordinate_system,
            only_solidmodel(sim_area),
            SemanticMeta(:simulated_area)
        )
        render!(
            floorplan.coordinate_system,
            only_solidmodel(chip_area),
            SemanticMeta(:writeable_area)
        )

        # Should not render to the solid model.
        render!(
            floorplan.coordinate_system,
            not_solidmodel(circle_polygon(5μm, 1°)),
            SemanticMeta(:circle)
        )

        # Add a NORENDER_META element that should be skipped in solid model rendering
        render!(
            floorplan.coordinate_system,
            Rectangle(2μm, 2μm) + Point(50μm, 50μm),
            DeviceLayout.NORENDER_META
        )
        # Also an element in a layer that will be designated as ignored by the target
        render!(
            floorplan.coordinate_system,
            Rectangle(2μm, 2μm) + Point(50μm, 50μm),
            SemanticMeta(:ignored)
        )

        check!(floorplan)
        build!(floorplan)

        # Render to a solid model
        tech = ProcessTechnology(
            (;
                base_negative=GDSMeta(),
                simulated_area=GDSMeta(2),
                chip_outline=GDSMeta(3),
                writeable_area=GDSMeta(4)
            ),
            (;
                height=(; simulated_area=-1mm),
                thickness=(; simulated_area=2mm, chip_outline=[250μm, 250μm]),
                chip_thicknesses=[250μm, 250μm],
                flipchip_gaps=[250μm]
            )
        )
        target = SchematicDrivenLayout.SolidModelTarget(
            tech;
            bounding_layers=[:simulated_area],
            substrate_layers=[:chip_outline],
            levelwise_layers=[:chip_outline],
            indexed_layers=[:port],
            ignored_layers=[:ignored],
            postrender_ops=[
                (
                    "substrates",
                    SolidModels.union_geom!,
                    ("chip_outline_L1_extrusion", "chip_outline_L2_extrusion", 3, 3)
                ),
                (
                    "vacuum",
                    SolidModels.difference_geom!,
                    ("simulated_area_extrusion", "substrates", 3, 3)
                ),
                (
                    "base_metal",
                    SolidModels.difference_geom!,
                    ("writeable_area", "base_negative")
                )
            ],
            retained_physical_groups=[
                ("substrates", 3),
                ("vacuum", 3),
                ("base_metal", 2),
                ("circle", 2),
                ("norender", 2),
                ("ignored", 2)
            ],
            solidmodel=true,
            simulation=true
        )

        sm = SolidModel("test", overwrite=true)

        render!(sm, floorplan, target)

        # Only the specified groups are kept, and only if actually present.
        @test SolidModels.hasgroup(sm, "substrates", 3)
        @test SolidModels.hasgroup(sm, "vacuum", 3)
        @test SolidModels.hasgroup(sm, "base_metal", 2)
        @test !SolidModels.hasgroup(sm, "chip_outline_L1_extrusion", 3)
        @test !SolidModels.hasgroup(sm, "chip_outline_L2_extrusion", 3)
        @test !SolidModels.hasgroup(sm, "simulated_area_extrusion", 3)
        @test !SolidModels.hasgroup(sm, "writeable_area", 2)
        @test !SolidModels.hasgroup(sm, "base_negative", 2)
        @test !SolidModels.hasgroup(sm, "circle", 2)

        # Verify that NORENDER_META element is not present (should be skipped even though it's retained)
        @test !SolidModels.hasgroup(sm, "norender", 2)
        @test !SolidModels.hasgroup(sm, "ignored", 2) # Same for `ignored_layers=[:ignored]`

        # The physical groups should be reindexed in decreasing order of dimension, and then
        # alphabetically
        @test sm["substrates", 3].grouptag == 1
        @test sm["vacuum", 3].grouptag == 2
        @test sm["base_metal", 2].grouptag == 3
        @test length(SolidModels.dimgroupdict(sm, 3)) == 2
        @test length(SolidModels.dimgroupdict(sm, 2)) == 1
        @test length(SolidModels.dimgroupdict(sm, 1)) == 0
        @test length(SolidModels.dimgroupdict(sm, 0)) == 0

        if mesh
            # Reduce the noise in the REPL
            SolidModels.gmsh.option.setNumber("General.Verbosity", 0)
            @test_nowarn SolidModels.gmsh.model.mesh.generate(3)
        end
        if gui
            SolidModels.gmsh.fltk.run()
        end
    end

    @testset "NativeRoundedComponent" begin
        @testset "SquareLattice" begin
            poly = SquareLattice(rounded=false)
            test_component(poly, 1, true)
            test_component(poly, 2, true)
            test_component(poly, 3, true)
        end

        @testset "Rounded SquareLattice" begin
            poly = SquareLattice(rounded=true)
            test_component(poly, 1, true)
            test_component(poly, 2, true)
            test_component(poly, 3, true)
        end

        @testset "NestedSquares" begin
            poly = NestedSquares(rounded=false)
            test_component(poly, 1, true)
            test_component(poly, 2, true)
            test_component(poly, 3, true)
        end

        @testset "Rounded NestedSquares" begin
            poly = NestedSquares(rounded=true)
            test_component(poly, 1, true)
            test_component(poly, 2, true)
            test_component(poly, 3, true)
        end

        @testset "TiledSquares" begin
            poly = TiledPolygons(rounded=false)
            test_component(poly, 1, true)
            test_component(poly, 2, true)
            test_component(poly, 3, true)
        end

        @testset "Rounded TiledSquares" begin
            poly = TiledPolygons(rounded=true)
            test_component(poly, 1, true)
            test_component(poly, 2, true)
            test_component(poly, 3, true)
        end
    end

end

@testitem "Schematic + SolidModel + Paths and Bridges" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout

    reset_uniquename!()
    BASE_NEGATIVE = SemanticMeta(:base_negative)

    function test_bridge(; meander=false, bridges=false)
        # Helper to define an airbridge
        function low_overlap_bridge(
            waveguide_style::Paths.SimpleCPW,
            bridge_meta::DeviceLayout.Meta,
            base_meta::DeviceLayout.Meta
        )
            wgt, wgg = waveguide_style.trace, waveguide_style.gap
            center_beam_width = 10μm
            foot_length = 10μm
            base_ground_overlap = 2μm
            total_beam_length = wgt + 2 * (wgg + base_ground_overlap + foot_length)
            base_margin = 4μm
            base_width = center_beam_width + 2 * base_margin
            base_length = wgt + 2 * (wgg + base_ground_overlap)
            cs = CoordinateSystem(uniquename("bridge"), nm)
            beam = centered(Rectangle(total_beam_length, center_beam_width))
            render!(cs, beam, bridge_meta)
            base = centered(Rectangle(base_length, base_width))
            render!(cs, base, base_meta)
            return cs
        end

        # Helper to define cpw tapering under bridge
        function tapered_bridge(
            waveguide_style::Paths.SimpleCPW,
            thin_trace_width::DeviceLayout.Coordinate,
            thin_trace_length::DeviceLayout.Coordinate,
            taper_length::DeviceLayout.Coordinate,
            gap_meta::DeviceLayout.Meta,
            bridge_meta::DeviceLayout.Meta,
            base_meta::DeviceLayout.Meta
        )
            cs = low_overlap_bridge(waveguide_style, bridge_meta, base_meta)

            wgt, wgg = waveguide_style.trace, waveguide_style.gap
            ttw, ttl, tpl = thin_trace_width, thin_trace_length, taper_length

            dy = 2μm
            trapezoid_right = Polygon([
                Point(0.5 * wgt + 0.5 * wgg, 0.5 * ttl + tpl + dy),
                Point(0.5 * wgt + 0.5 * wgg, -(0.5 * ttl + tpl + dy)),
                Point(0.5 * ttw, zero(ttl))
            ])

            trapezoid_left = copy(trapezoid_right) |> Rotation(pi)
            render!.(cs, [trapezoid_right, trapezoid_left], gap_meta)
            return cs
        end

        # Build schematic graph
        g = SchematicGraph("test")

        # Create abstract components
        cpw_width = 10μm
        cpw_gap = 6μm
        cpw_style = Paths.SimpleCPW(cpw_width, cpw_gap)
        air_bridge = tapered_bridge(
            cpw_style,
            5µm,
            9µm,
            5µm,
            BASE_NEGATIVE,
            SemanticMeta(:air_bridge),
            SemanticMeta(:base)
        )

        # Readout path
        total_length = 600μm
        bridge_spacing = 100μm
        p_readout = Path(Point(0μm, 0μm); α0=π / 2, metadata=BASE_NEGATIVE, name="p_ro")
        straight!(p_readout, total_length / 2, cpw_style)
        if meander
            meander!(p_readout, total_length, total_length / 4, 50μm, 180°)
        end
        if bridges
            # Air bridges over the path
            attach!(
                p_readout,
                sref(air_bridge, rot=π / 2),
                bridge_spacing .* [1:(floor(Int, total_length / 2 / bridge_spacing) - 1)],
                i=1
            )
        end

        # Readout lumped ports - one at each end in the central gap
        csport = CoordinateSystem(uniquename("port"), nm)
        render!(
            csport,
            only_simulated(centered(Rectangle(cpw_width, cpw_width))),
            SemanticMeta(:port)
        )
        attach!(p_readout, sref(csport), cpw_width / 2, i=1) # left section @ start
        attach!(p_readout, sref(csport), total_length / 2 - cpw_width / 2, i=1) # right section @ end
        p_readout_node = add_node!(g, p_readout)

        ## Position the components
        floorplan = plan(g; log_dir=nothing)

        # Setup an optional "fine mesh" size field.
        refinement_style = OptionalStyle(
            MeshSized(1.0μm, 0.8),
            :finemesh,
            false_style=MeshSized(10.0μm, 0.9),
            default=false
        )
        sizing = [
            styled(
                centered(Rectangle(400μm, 400μm), on_pt=Point(500μm, 0μm)),
                refinement_style
            ),
            styled(Ellipse(Point(-100.0μm, 0.0μm), (10.0μm, 4.0μm), 45°), refinement_style)
        ]

        render!.(floorplan.coordinate_system, sizing, SemanticMeta(:sizes))

        sim_area = union2d(halo(bounds(floorplan), 1mm))
        chip = union2d(halo(bounds(floorplan), 1mm))

        render!(floorplan.coordinate_system, sim_area, SemanticMeta(:simulated_area))
        render!(floorplan.coordinate_system, sim_area, SemanticMeta(:writeable_area))

        render!(floorplan.coordinate_system, chip, SemanticMeta(:chip_outline))
        render!(floorplan.coordinate_system, chip, SemanticMeta(:chip_outline, level=2))

        check!(floorplan)

        # Render to a solid model
        tech = ProcessTechnology(
            (;
                base_negative=GDSMeta(),
                simulated_area=GDSMeta(2),
                writeable_area=GDSMeta(3),
                chip_outline=GDSMeta(4)
            ),
            (;
                height=(; simulated_area=-2mm, bridge_platform=1μm),
                thickness=(; simulated_area=5mm, chip_outline=[1mm, 1mm]),
                chip_thicknesses=[1mm, 1mm],
                flipchip_gaps=[1mm]
            )
        )

        # Only add bridge postrendering if they're present.
        bridge_postrender =
            bridges ?
            SolidModels.staple_bridge_postrendering(
                levels=[1],
                base="base",
                bridge="air_bridge",
                bridge_height=10μm
            ) : []

        target = SchematicDrivenLayout.SolidModelTarget(
            tech;
            bounding_layers=[:simulated_area],
            substrate_layers=[:chip_outline],
            levelwise_layers=[:chip_outline, :base, :air_bridge],
            indexed_layers=[:port],
            postrender_ops=[
                (
                    "substrates",
                    SolidModels.union_geom!,
                    ("chip_outline_L1_extrusion", "chip_outline_L2_extrusion", 3, 3),
                    :remove_object => true,
                    :remove_tool => true
                ),
                (
                    "vacuum",
                    SolidModels.difference_geom!,
                    ("simulated_area_extrusion", "substrates", 3, 3)
                ),
                bridge_postrender...,
                (
                    "base_metal",
                    SolidModels.difference_geom!,
                    ("writeable_area", "base_negative"),
                    :remove_object => true,
                    :remove_tool => true
                ),
                (
                    "conductor",
                    SolidModels.union_geom!,
                    ("base_metal", "bridge_metal"),
                    :remove_object => true
                ),
                (
                    "conductor",
                    SolidModels.difference_geom!,
                    ("conductor", ["port_1", "port_2"])
                )
            ],
            retained_physical_groups=[
                ("vacuum", 3),
                ("substrates", 3),
                ("conductor", 2),
                ("bridge_metal", 2),
                ("port_1", 2),
                ("port_2", 2),
                ("exterior_boundary", 2)
            ],
            simulation=true,
            solidmodel=true,
            fine_mesh=true
        )

        sm = SolidModel("test", overwrite=true)
        # SolidModels.set_gmsh_option("")
        render!(sm, floorplan, target)

        @test SolidModels.hasgroup(sm, "substrates", 3)
        @test SolidModels.hasgroup(sm, "vacuum", 3)
        @test SolidModels.hasgroup(sm, "conductor", 2)
        @test SolidModels.hasgroup(sm, "port_1", 2)
        @test SolidModels.hasgroup(sm, "port_2", 2)
        @test !bridges || SolidModels.hasgroup(sm, "bridge_metal", 2)
        @test SolidModels.hasgroup(sm, "exterior_boundary", 2)
        @test !SolidModels.hasgroup(sm, "chip_outline_L1_extrusion", 3)
        @test !SolidModels.hasgroup(sm, "chip_outline_L2_extrusion", 3)
        @test !SolidModels.hasgroup(sm, "simulated_area_extrusion", 3)
        @test !SolidModels.hasgroup(sm, "writeable_area", 2)
        @test !SolidModels.hasgroup(sm, "base_negative", 2)

        # Reduce the noise in the REPL
        SolidModels.gmsh.option.setNumber("General.Verbosity", 0)
        SolidModels.reset_mesh_control!()
        @test_nowarn SolidModels.gmsh.model.mesh.generate(3)

        num_tri = SolidModels.gmsh.option.get_number("Mesh.NbTriangles")

        # Half the global scale, should be a finer mesh.
        SolidModels.mesh_scale(0.5)
        SolidModels.gmsh.model.mesh.clear() # Force gmsh to regenerate the mesh
        @test_nowarn SolidModels.gmsh.model.mesh.generate(3)
        @test SolidModels.gmsh.option.get_number("Mesh.NbTriangles") > num_tri

        # Less aggressive grading -- results in slower mesh size growth away from sized entities
        # with default grading (nonstyled paths)
        SolidModels.mesh_scale(1.0)
        SolidModels.mesh_grading_default(0.7)
        SolidModels.gmsh.model.mesh.clear()
        @test_nowarn SolidModels.gmsh.model.mesh.generate(3)
        @test SolidModels.gmsh.option.get_number("Mesh.NbTriangles") > num_tri
        return sm
    end

    @testset "CPWRendering" begin
        @testset "StraightNoBridge" begin
            sm = test_bridge(meander=false, bridges=false)
            @test length(SolidModels.entitytags(sm["conductor", 2])) == 4
            @test length(SolidModels.entitytags(sm["port_1", 2])) == 1
            @test length(SolidModels.entitytags(sm["port_2", 2])) == 1
            @test length(SolidModels.entitytags(sm["exterior_boundary", 2])) == 5 * 4 + 2
            @test length(SolidModels.entitytags(sm["substrates", 3])) == 2
            @test length(SolidModels.entitytags(sm["vacuum", 3])) == 3
        end

        @testset "StraightBridge" begin
            sm = test_bridge(meander=false, bridges=true)
            @test length(SolidModels.entitytags(sm["conductor", 2])) == 10
            @test length(SolidModels.entitytags(sm["port_1", 2])) == 1
            @test length(SolidModels.entitytags(sm["port_2", 2])) == 1
            @test length(SolidModels.entitytags(sm["bridge_metal", 2])) == 6
            @test length(SolidModels.entitytags(sm["exterior_boundary", 2])) == 5 * 4 + 2
            @test length(SolidModels.entitytags(sm["substrates", 3])) == 2
            @test length(SolidModels.entitytags(sm["vacuum", 3])) == 3
        end

        @testset "MeanderNoBridge" begin
            sm = test_bridge(meander=true, bridges=false)
            @test length(SolidModels.entitytags(sm["conductor", 2])) == 4
            @test length(SolidModels.entitytags(sm["port_1", 2])) == 1
            @test length(SolidModels.entitytags(sm["port_2", 2])) == 1
            @test length(SolidModels.entitytags(sm["exterior_boundary", 2])) == 5 * 4 + 2
            @test length(SolidModels.entitytags(sm["substrates", 3])) == 2
            @test length(SolidModels.entitytags(sm["vacuum", 3])) == 3
        end

        @testset "MeanderBridge" begin
            sm = test_bridge(meander=true, bridges=true)
            @test length(SolidModels.entitytags(sm["conductor", 2])) == 10
            @test length(SolidModels.entitytags(sm["port_1", 2])) == 1
            @test length(SolidModels.entitytags(sm["port_2", 2])) == 1
            @test length(SolidModels.entitytags(sm["bridge_metal", 2])) == 6
            @test length(SolidModels.entitytags(sm["exterior_boundary", 2])) == 5 * 4 + 2
            @test length(SolidModels.entitytags(sm["substrates", 3])) == 2
            @test length(SolidModels.entitytags(sm["vacuum", 3])) == 3
        end
    end
end

@testitem "Schematic + SolidModel + Overlap Path" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout: AbstractComponent

    reset_uniquename!()
    BASE_NEGATIVE = SemanticMeta(:base_negative)

    using LinearAlgebra

    function overlap_path(; path_style, turn_radius=50μm)

        # Build schematic graph
        g = SchematicGraph("single_transmon")

        # Meandering path
        finger_length = 1000μm
        pa = Path(Point(0μm, 0μm); α0=π / 2, name="p", metadata=BASE_NEGATIVE)
        straight!(pa, finger_length / 2, path_style)
        turn!(pa, π, turn_radius, path_style)
        straight!(pa, finger_length / 2, path_style)
        turn!(pa, -π, turn_radius, path_style)
        straight!(pa, finger_length / 2, path_style)
        turn!(pa, π, turn_radius, path_style)
        straight!(pa, finger_length / 2, path_style)
        turn!(pa, -π, turn_radius, path_style)
        straight!(pa, finger_length / 2, path_style)

        pa_node = add_node!(g, pa)

        ## Position the components
        floorplan = plan(g; log_dir=nothing)

        sim_area = union2d(halo(bounds(floorplan), 1mm))
        chip = union2d(halo(bounds(floorplan), 1mm))

        render!(floorplan.coordinate_system, sim_area, SemanticMeta(:simulated_area))
        render!(floorplan.coordinate_system, sim_area, SemanticMeta(:writeable_area))
        render!(floorplan.coordinate_system, chip, SemanticMeta(:chip_outline))

        check!(floorplan)
        build!(floorplan)

        substrate_z = 250μm
        air_z = 0.5mm

        # Render to a solid model
        tech = ProcessTechnology(
            (;
                base_negative=GDSMeta(),
                simulated_area=GDSMeta(2),
                writeable_area=GDSMeta(3),
                chip_outline=GDSMeta(4)
            ),
            (;
                height=(; simulated_area=-air_z - substrate_z, chip_outline=0μm),
                thickness=(;
                    simulated_area=2 * air_z + substrate_z,
                    chip_outline=[substrate_z]
                ),
                chip_thicknesses=[substrate_z]
            )
        )
        sm_target = SchematicDrivenLayout.SolidModelTarget(
            tech;
            bounding_layers=[:simulated_area],
            substrate_layers=[:chip_outline],
            levelwise_layers=[:chip_outline],
            indexed_layers=[:port],
            postrender_ops=[
                (
                    "substrates",
                    SolidModels.union_geom!,
                    ("chip_outline_L1_extrusion", "chip_outline_L1_extrusion", 3, 3)
                ),
                (
                    "vacuum",
                    SolidModels.difference_geom!,
                    ("simulated_area_extrusion", "substrates", 3, 3)
                ),
                (
                    "conductor",
                    SolidModels.difference_geom!,
                    ("writeable_area", "base_negative"),
                    :remove_tool => true
                )
            ],
            retained_physical_groups=[
                ("vacuum", 3),
                ("substrates", 3),
                ("conductor", 2),
                ("exterior_boundary", 2)
            ],
            simulation=true,
            solidmodel=true
        )

        sm = SolidModel("test", overwrite=true)
        @test_nowarn render!(sm, floorplan, sm_target)
        return sm
    end

    @testset "OverlappingTrace" begin
        @testset "ExactDegeneracyTrace" begin
            overlap_path(path_style=Paths.Trace(100μm), turn_radius=50μm)
        end
        @testset "ClippedDegeneracyTrace" begin
            overlap_path(path_style=Paths.Trace(100μm), turn_radius=40μm)
        end
        @testset "ExactDegeneracyCPW" begin
            overlap_path(path_style=Paths.CPW(100μm, 50μm), turn_radius=100μm)
        end
        @testset "ClippedDegeneracyCPW" begin
            overlap_path(path_style=Paths.CPW(100μm, 50μm), turn_radius=75μm)
        end
    end
end
