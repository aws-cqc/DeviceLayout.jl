@testitem "Schematic-Driven Layout" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout

    import .SchematicDrivenLayout: AbstractComponent, AbstractCompositeComponent
    import .SchematicDrivenLayout: nodes, component, check_rotation, allowed_rotation_angles
    import .SchematicDrivenLayout.ExamplePDK: add_wave_ports!

    reset_uniquename!()

    BASE_NEGATIVE = SemanticMeta(:base_negative)
    BASE_POSITIVE = SemanticMeta(:base_positive)

    @compdef struct TestComponent <: AbstractComponent{typeof(1.0nm)}
        name::String = "test"
        hooks::NamedTuple = (;)
    end
    SchematicDrivenLayout.hooks(comp::TestComponent) = comp.hooks

    @compdef struct TestDirectionalComponent <: AbstractComponent{typeof(1.0nm)}
        name::String = "test"
        hooks::NamedTuple = (;)
    end
    SchematicDrivenLayout.hooks(comp::TestDirectionalComponent) = comp.hooks
    check_rotation(::TestDirectionalComponent) = true
    allowed_rotation_angles(::TestDirectionalComponent) = [0, pi / 2]

    @testset "Built-in components" begin
        # Component works like any GeometryStructure
        ar = SchematicDrivenLayout.ArrowAnnotation(width=1μm)
        cs = CoordinateSystem("test", nm)
        place!(cs, ar)
        cs2 = CoordinateSystem("test2", nm)
        addref!(cs2, sref(cs, Point(10μm, 0μm); rot=90°))
        @test bounds(flatten(cs2)) ≈ rotate90(bounds(geometry(ar)), 1) + Point(10μm, 0μm)
        ar2 = ar("newname"; length=1μm)
        @test ar2.width == ar.width
        @test ar2.length == 1000.0nm
        @test keys(SchematicDrivenLayout.non_default_parameters(ar2)) ==
              (:name, :length, :width)

        # Can find references within component
        c = Cell("test", nm)
        c2 = Cell("test2", nm)
        ref = sref(c, Point(8μm, -10μm); xrefl=true, rot=45°)
        addref!(c2, ref)
        gc = GDSComponent(c2, (; arr=[PointHook(0mm, i * 1mm, 90°) for i = 1:4]))
        @test hooks(gc, :arr_2) == PointHook(0mm, 2mm, 90°)
        ref2 = sref(gc, Point(2μm, 5μm); rot=30°)
        addref!(cs2, ref2)
        @test transformation(cs2, ref) ≈ transformation(ref2) ∘ transformation(ref)

        sp = Spacer(; p1=Point(1mm, 1mm))
        tr = transformation(hooks(sp).p1_south, hooks(ar).nock)
        @test isapprox_angle(rotation(tr), -π / 2)

        bc = BasicComponent(flatten(cs2))
        @test hooks(bc) == compass()
        @test isapprox(footprint(bc), bounds(cs2), atol=1e-9nm)
        @test isnothing(allowed_rotation_angles(bc))
        @test SchematicDrivenLayout.make_footprint(GDSMeta())(bc).elements[1] ==
              footprint(bc)

        # Default preference NoUnits
        @test coordinatetype(Component) == typeof(1.0nm2nm)

        wv = WeatherVane()
        @test in_direction(hooks(wv, :east)) == 0°
    end

    @variant CutoutFlipchipArrow SchematicDrivenLayout.ArrowAnnotation{typeof(1.0nm)} map_meta =
        facing new_defaults = (; cutout_margin=20μm)
    function SchematicDrivenLayout._geometry!(
        cs::CoordinateSystem,
        arrow::CutoutFlipchipArrow
    )
        _geometry!(cs, base_variant(arrow))
        map_metadata!(cs, facing)
        return place!(
            cs,
            offset(bounds(cs), parameters(arrow).cutout_margin)[1],
            SemanticMeta(:base_negative)
        )
    end
    @testset "Variants" begin
        cs = geometry(CutoutFlipchipArrow(; cutout_margin=10μm))
        @test bounds(cs) ≈ Rectangle(
            bounds(CutoutFlipchipArrow()).ll + Point(10μm, 10μm),
            bounds(CutoutFlipchipArrow()).ur - Point(10μm, 10μm)
        )
        @test level(cs.element_metadata[1]) == 2
        @test level(cs.element_metadata[2]) == 1
        manually_flipped = map_metadata(
            SchematicDrivenLayout.ArrowAnnotation(; name=uniquename("arrow")),
            facing
        )
        cs2 = geometry(manually_flipped)
        @test level(cs2.element_metadata[1]) == 2
    end

    @testset "Macros" begin
        widths = [1, 2, 3, 4, 5]
        texts = ["first", "second", "third"]
        l2 = 5
        @component arrow[1:3] = SchematicDrivenLayout.ArrowAnnotation{typeof(1.0)} begin
            width .= widths[1:2:end]
            text .= texts
            length = l2 / 2
        end
        @test all(getindex.(parameters.(arrow), :text) .== texts)
        @test all(getindex.(parameters.(arrow), :width) .== widths[1:2:end])
        @test all(getindex.(parameters.(arrow), :length) .== l2 / 2)
        @component arrow_arr[1:3, 1:2] = arrow[1] begin
            text .= [texts texts]
        end
        @test size(arrow_arr) == (3, 2)
        @test arrow_arr[3, 2].length == arrow[1].length

        @compdef struct NoName <: AbstractComponent{typeof(1.0nm)}
            x::Int
            y
        end
        @test name(NoName(x=1, y=2)) == "NoName"
        @test_throws UndefKeywordError NoName(x=1)
        @test_throws InexactError NoName(x=1.5, y=2)
    end

    @testset "Schematics" begin
        @testset "Path attachments" begin
            g = SchematicGraph("test_attach")
            pa = Path(nm)
            straight!(pa, 100μm, Paths.SimpleTrace(10μm))
            pan = add_node!(g, pa)
            arrow = attach!(g, pan, CutoutFlipchipArrow() => :tip, 50μm; i=1, location=-1)
            sch = plan(g; log_dir=nothing)
            @test hooks(sch, arrow).tip.p ≈ Point(50μm, 5μm)
            @test hooks(sch, arrow).tip.in_direction == pi / 2
        end

        g = SchematicGraph("test_graph")
        ## Create abstract components
        bq = TestComponent(
            name="bq",
            hooks=(
                z=PointHook(Point(0nm, 0nm), π / 2),
                xy=PointHook(Point(-100nm, -100nm), 0)
            )
        )

        xyline = TestComponent(
            name="xy",
            hooks=(
                qubit=PointHook(Point(0nm, 0nm), π / 2),
                feedline=PointHook(Point(0nm, 100nm), -π / 2)
            )
        )

        zline = TestComponent(
            name="z",
            hooks=(
                qubit=PointHook(Point(100nm, 0nm), π),
                feedline=PointHook(Point(0nm, 0nm), 0)
            )
        )

        @component template = TestComponent begin
            name = "template"
            hooks = (
                xyline=PointHook(Point(-0.2mm, -1.0mm), -π / 2),
                zline=PointHook(Point(0.2mm, -1.0mm), -π / 2),
                bq=PointHook(Point(0.5mm, 0.5mm), -π / 2)
            )
        end

        ## Build schematic graph
        template_node = add_node!(g, template)
        # Create an instance of bq in the schematic
        bq_node = fuse!(g, template_node => :bq, bq => :z)
        # Add instances of the other components, attached to bq
        z_node = fuse!(g, bq_node => :z, zline => :qubit)
        xy_node = fuse!(g, bq_node => :xy, xyline => :qubit)

        # Unit tests
        @test !(SchematicDrivenLayout.MetaGraphs.is_directed(g))
        @test SchematicDrivenLayout.MetaGraphs.weighttype(g) == Float64
        SchematicDrivenLayout.set_prop!(g, bq_node, :test, true)
        @test SchematicDrivenLayout.get_prop(g, bq_node, :test)
        e12 = SchematicDrivenLayout.Graphs.SimpleGraphs.SimpleEdge(1, 2)
        @test SchematicDrivenLayout.get_prop(g, e12, template_node) == :bq
        @test SchematicDrivenLayout.get_prop(g, e12, 2) == :z

        ## Turn the schematic into polygons
        floorplan = plan(g; log_dir=nothing)
        check!(floorplan)
        @test hooks(floorplan, bq_node).z.p == hooks(floorplan, z_node).qubit.p
        @test hooks(floorplan, bq_node).xy.p == hooks(floorplan, xy_node).qubit.p
        @test hooks(floorplan, z_node).feedline.p ≈ Point(0.5mm, 0.5mm - 100nm)

        global_cell = Cell("chip", nm)
        render!(global_cell, floorplan.coordinate_system)

        # Test using manually defined hooks
        g2 = SchematicGraph("test_graph_attach")
        template_node2 = add_node!(g2, template(name="template_2"))
        @test_throws "No matching hook" fuse!(g2, template_node2 => :bq, bq)
        SchematicDrivenLayout.matching_hook(::TestComponent, ::Symbol, ::TestComponent) = :z
        bq_node2 = fuse!(g2, template_node2 => :bq, bq)
        z_node2 = fuse!(g2, bq_node2, zline => :qubit)
        @test_throws "No matching hook" fuse!(g2, bq_node2, xyline)
        SchematicDrivenLayout.matching_hooks(::TestComponent, ::TestComponent) =
            (:xy, :qubit)
        xy_node2 = fuse!(g2, bq_node2, xyline)
        floorplan2 = plan(g2; log_dir=nothing)
        @test transformation(floorplan2, bq_node2) == transformation(floorplan, bq_node)
        @test transformation(floorplan2, z_node2) == transformation(floorplan, z_node)
        @test transformation(floorplan2, xy_node2) == transformation(floorplan, xy_node)

        # Test using matching hooks
        g2 = SchematicGraph("test_matching")
        template_node2 = add_node!(g2, template)
        bq_node2 = fuse!(g2, template_node2 => :bq, bq => hooks(bq, :z))
        z_node2 = fuse!(g2, bq_node2 => hooks(bq, :z), zline => hooks(zline, :qubit))
        xy_node2 = fuse!(g2, bq_node2 => hooks(bq, :xy), xyline => :qubit)
        floorplan2 = plan(g2; log_dir=nothing)
        @test transformation(floorplan2, bq_node2) == transformation(floorplan, bq_node)
        @test transformation(floorplan2, z_node2) == transformation(floorplan, z_node)
        @test transformation(floorplan2, xy_node2) == transformation(floorplan, xy_node)

        # Reset matching hooks to something that returns original error
        SchematicDrivenLayout.matching_hook(t1::TestComponent, s::Symbol, ::TestComponent) =
            SchematicDrivenLayout.matching_hook(t1, s, Spacer())
        SchematicDrivenLayout.matching_hooks(t1::TestComponent, ::TestComponent) =
            SchematicDrivenLayout.matching_hooks(t1, Spacer())

        @testset "Replace" begin
            append_x(tc, p) =
                TestComponent(name=(tc.name * "$(ustrip(mm, p.x))"), hooks=tc.hooks)
            position_dependent_replace!(
                floorplan,
                TestComponent,
                append_x,
                schematic_origin_globalcoords=Point(10mm, -10mm)
            )
            @test SchematicDrivenLayout.component(template_node).name ==
                  template.name * "10.0"
            @test SchematicDrivenLayout.component(bq_node).name == bq.name * "10.5"
            @test SchematicDrivenLayout.component(xy_node).name == xyline.name * "10.4999"
            @test SchematicDrivenLayout.component(z_node).name == zline.name * "10.5"
            # Check that building the floorplan after this uses the changes
            check!(floorplan)
            build!(floorplan)
            @test coordsys(coordsys(refs(floorplan)[1]).refs[1]).name ==
                  template.name * "10.0"
        end

        @testset "Routes" begin
            sty = Paths.SimpleCPW(1000nm, 600nm)
            meta = GDSMeta(0)
            r = Route(
                Paths.BSplineRouting(),
                hooks(floorplan, z_node).feedline,
                hooks(floorplan, template_node).zline
            )
            rc = RouteComponent("r_z", r, false, sty, meta)
            route!(
                g,
                Paths.BSplineRouting(),
                template_node => :zline,
                z_node => :feedline,
                sty,
                meta
            )
            plan(g; log_dir=nothing)

            r2 = route!(
                g,
                Paths.StraightAnd90(min_bend_radius=1μm),
                bq_node => :z, # 0.5mm, 0.5mm, -pi/2 (in)
                z_node => :feedline, # 0.5mm, 0.5mm - 100nm, -pi/2 (in)
                sty,
                meta;
                waypoints=[
                    Point(0.1mm, 0.1mm),
                    Point(0.2mm, 0.2mm),
                    Point(0.3mm, 0.1mm),
                    Point(0.2mm, 0mm)
                ]
            )
            floorplan = plan(g; log_dir=nothing)
            cs = CoordinateSystem("attach", nm)
            render!(cs, Rectangle(0.02mm, 0.01mm), GDSMeta(100))
            rc = r2.component
            attach!(
                rc,
                sref(cs),
                range(0mm, pathlength(SchematicDrivenLayout.path(rc)), length=3)
            )
            check!(floorplan)
            build!(floorplan)
            flat = flatten(floorplan.coordinate_system)
            @test count(flat.element_metadata .== GDSMeta(100)) == 3

            r2.component.sty[1] =
                Paths._overlay!(r2.sty[1], Paths.Trace(1000nm), GDSMeta(1))
            empty!(r2._path)
            path = SchematicDrivenLayout.path(r2.component)
            @test path[1].sty.s isa Paths.OverlayStyle

            r1 = route!(
                g,
                Paths.StraightAnd90(min_bend_radius=1μm),
                bq_node => :z,
                z_node => :feedline,
                sty,
                meta
            )
            log_dir = mktempdir()
            floorplan = plan(g; log_dir=log_dir)
            check!(floorplan)
            @test_throws "Encountered errors" build!(floorplan)
            build!(floorplan; strict=:no)
            @test SchematicDrivenLayout.max_level_logged(floorplan, :build) == Logging.Error
            @test contains(
                read(floorplan.logger.logname, String),
                "Could not automatically route"
            )
        end

        @testset "Check" begin
            @testset "Check rotation" begin
                compass = TestDirectionalComponent(
                    name="compass",
                    hooks=(
                        n=PointHook(Point(0nm, 100nm), 3pi / 2),
                        e=PointHook(Point(100nm, 0nm), pi),
                        s=PointHook(Point(0nm, -100nm), pi / 2),
                        w=PointHook(Point(-100nm, 0nm), 0)
                    )
                )

                g = SchematicGraph("test_g_2")

                # first make an array going from left to right, where all compasses
                # have N facing north (an allowed orientation)
                node = add_node!(g, compass)
                for ii = 1:4
                    node = fuse!(g, node => :e, compass => :w)
                end
                floorplan = plan(g; log_dir=nothing)
                @test floorplan.checked[] == false
                check!(floorplan) # check! should succeed
                @test floorplan.checked[] == true
                build!(floorplan)

                # now make an array going from right to left, where the last compass is
                # connected to the wrong hook, resulting in a disallowed rotation (N facing east)
                node = add_node!(g, compass)
                for ii = 1:3
                    node = fuse!(g, node => :w, compass => :e)
                end
                node = fuse!(g, node => :w, compass => :n) # add rotated compass
                floorplan = plan(g; log_dir=nothing)
                @test floorplan.checked[] == false
                @test_throws ErrorException check!(floorplan) # check! should fail
                @test floorplan.checked[] == false
                @test_throws ErrorException build!(floorplan) # build should fail too

                # Test within composite component
                composite = BasicCompositeComponent(g)
                g = SchematicGraph("test_g_4")
                add_node!(g, composite)
                floorplan = plan(g; log_dir=nothing)
                # check! should fail even though the problem is hidden inside composite
                @test_throws ErrorException check!(floorplan)

                g = SchematicGraph("test_g_3")

                # now make an L-shaped array, where all compasses having N facing north,
                # except the last compass at the bottom left of the L which has N facing west
                # (also an allowed orientation)
                node = add_node!(g, compass)
                for ii = 1:3
                    node = fuse!(g, node => :s, compass => :n)
                end
                for ii = 1:3
                    node = fuse!(g, node => :e, compass => :w)
                end
                node = fuse!(g, node => :e, compass => :n)
                floorplan = plan(g; log_dir=nothing)
                @test floorplan.checked[] == false
                check!(floorplan) # check should succeed
                @test floorplan.checked[] == true
                build!(floorplan)

                # now make the same L, except now we manually set ref.xrefl = true for
                # the ref at the corner of the L, which should mirror the bottom part
                # and change the orientation of the last component to N facing east
                # (a disallowed rotation)
                node = add_node!(g, compass)
                for ii = 1:3
                    node = fuse!(g, node => :s, compass => :n)
                end
                for ii = 1:3
                    node = fuse!(g, node => :e, compass => :w)
                end
                node = fuse!(g, node => :e, compass => :n)
                floorplan = plan(g; log_dir=nothing)
                # node 4 is the corner of the L
                floorplan[nodes(g)[4]].xrefl = true
                @test floorplan.checked[] == false
                @test_throws ErrorException check!(floorplan) # check! should fail
                @test floorplan.checked[] == false
                @test_throws ErrorException build!(floorplan) # build should fail too
            end
        end

        @testset "Cycles" begin
            ## Create abstract components
            @component qubit[1:4] = TestComponent begin
                hooks = (
                    hook1=PointHook(Point(0nm, 0nm), π / 2),
                    hook2=PointHook(Point(-100nm, -100nm), 0)
                )
            end

            @testset "happypath_cycle_with_skippable_edges" begin
                g = SchematicGraph("test_graph")

                comp1_node = add_node!(g, qubit[1])
                comp2_node = fuse!(
                    g,
                    comp1_node => :hook1,
                    qubit[2] => :hook2;
                    PLAN_SKIPS_EDGE => true
                )
                comp3_node = fuse!(g, comp2_node => :hook1, qubit[3] => :hook2)
                comp4_node = fuse!(g, comp3_node => :hook1, qubit[4] => :hook2)
                fuse!(g, comp4_node => :hook1, comp1_node => :hook1)

                ## Turn the schematic into polygons
                floorplan = plan(g; log_dir=nothing)
                check!(floorplan)
                @test true
            end

            @testset "consistent_cycle_without_skippable_edges" begin
                g = SchematicGraph("test_graph")
                ## Create abstract components

                ## Build schematic graph
                comp1_node = add_node!(g, qubit[1])
                comp2_node = fuse!(g, comp1_node => :hook1, qubit[2] => :hook2)
                comp3_node = fuse!(g, comp2_node => :hook1, qubit[3] => :hook2)
                comp4_node = fuse!(g, comp3_node => :hook1, qubit[4] => :hook2)
                fuse!(g, comp4_node => :hook1, comp1_node => :hook2)
                plan(g; log_dir=nothing)
                log_dir = mktempdir()
                floorplan = plan(g; strict=:no, log_dir=log_dir)
                @test SchematicDrivenLayout.max_level_logged(floorplan, :plan) ==
                      Logging.Debug
            end

            @testset "failure_cycle_without_skippable_edges" begin
                g = SchematicGraph("test_graph")
                ## Create abstract components

                ## Build schematic graph
                comp1_node = add_node!(g, qubit[1])
                comp2_node = fuse!(g, comp1_node => :hook1, qubit[2] => :hook2)
                comp3_node = fuse!(g, comp2_node => :hook1, qubit[3] => :hook2)
                comp4_node = fuse!(g, comp3_node => :hook1, qubit[4] => :hook2)
                fuse!(g, comp4_node => :hook1, comp1_node => :hook1)
                @test_throws "Encountered errors" plan(g; log_dir=nothing)
                log_dir = mktempdir()
                floorplan = plan(g; strict=:no, log_dir=log_dir)
                @test SchematicDrivenLayout.max_level_logged(floorplan, :plan) ==
                      Logging.Error
                @test contains(read(floorplan.logger.logname, String), "is overconstrained")
            end
        end
    end

    @testset "Targets" begin
        tech = ProcessTechnology((; base_negative=GDSMeta()), (;))
        meta = SemanticMeta(:base_negative)
        rect = Rectangle(10μm, 10μm)

        # Direct rounding
        cs = CoordinateSystem("test", nm)
        cell = Cell("testcell", nm)
        render!(cs, Polygons.Rounded(1μm)(rect), layer_record(tech)[layer(meta)])
        render!(cell, cs)
        p0 = cell.elements[1]

        # With rounding optional
        cs = CoordinateSystem("test", nm)
        cell = Cell("testcell", nm)
        target = ArtworkTarget(tech)
        rrect = OptionalStyle(rect, DeviceLayout.Polygons.Rounded(1μm), :rounding)
        render!(cs, rrect, meta)
        render!(cell, cs, target)
        p1 = cell.elements[1]

        # Optional rounding off
        target = SimulationTarget(tech, rendering_options=(; rounding=false))
        render!(cell, cs, target)
        p2 = cell.elements[2]

        # Use metadata atol (ArtworkTarget uses atol with fallback)
        cs = CoordinateSystem("test", nm)
        target = ArtworkTarget(tech)
        arrect = ToTolerance(rrect, 0.01μm)
        render!(cs, arrect, meta)
        render!(cell, cs, target)
        p3 = cell.elements[3]

        # Try norender
        cs = CoordinateSystem("test", nm)
        l0 = length(cell.elements)
        anrrect = ToTolerance(DeviceLayout.NoRender(rrect), 0.01μm)
        render!(cs, anrrect, meta)
        render!(cell, cs, target)
        @test length(cell.elements) == l0

        # Use (higher) target atol
        cs = CoordinateSystem("test", nm)
        target = ArtworkTarget(tech, rendering_options=(; atol=0.1μm))
        render!(cs, rrect, meta)
        render!(cell, cs, target)
        p4 = cell.elements[4]

        @test length(p0.p) > 4
        @test length(p1.p) == length(p0.p)
        @test length(p2.p) == 4
        @test length(p3.p) > 4
        @test length(p3.p) < length(p0.p)
        @test length(p4.p) > 4
        @test length(p4.p) < length(p3.p)

        # Metadata mapping
        cs = CoordinateSystem("test", nm)
        render!(cs, rect, meta)
        render!(cs, rect, facing(meta))
        render!(cs, rect, SemanticMeta(:GDS2_2, index=2, level=2))
        render!(cs, rect, DeviceLayout.UNDEF_META)
        render!(cs, rect, DeviceLayout.NORENDER_META)
        render!(cs, rect, GDSMeta(2, 2))

        cell = Cell("test", nm)
        render!(cell, cs, ArtworkTarget(tech; levels=[1])) # meta, undef_meta, GDSMeta(2,2)
        @test cell.element_metadata == [GDSMeta(), GDSMeta(), GDSMeta(2, 2)]
        cell = Cell("test", nm)
        render!(cell, cs, ArtworkTarget(tech; levels=[2])) # facing(meta), (:GDS2_2,2,2), GDSMeta(2,2)
        @test cell.element_metadata == [GDSMeta(), GDSMeta(2, 2), GDSMeta(2, 2)]
        cell = Cell("test", nm)
        render!(cell, cs, ArtworkTarget(tech; levels=[1, 2], indexed_layers=[:GDS2_2]))
        @test cell.element_metadata ==
              [GDSMeta(), GDSMeta(300), GDSMeta(302, 4), GDSMeta(), GDSMeta(2, 2)]
        @test SchematicDrivenLayout.map_layer(ArtworkTarget(tech), SemanticMeta(:GDS2)) ==
              GDSMeta(2)

        # Manual map_meta_dict override
        target = ArtworkTarget(tech; levels=[1])
        target.map_meta_dict[meta] = nothing
        target.map_meta_dict[GDSMeta(2, 2)] = GDSMeta(3, 3)
        cell = Cell("test", nm)
        render!(cell, cs, target) # undef_meta, GDSMeta(2,2)
        @test cell.element_metadata == [GDSMeta(), GDSMeta(3, 3)]
    end

    @variant TestCompVariant TestComponent new_defaults =
        (jj_width=nothing, width=nothing, height=nothing)
    @testset "Composite components" begin
        g = SchematicGraph("xyz")
        bq = TestCompVariant(;
            hooks=(
                z  = PointHook(Point(0nm, 0nm), π / 2),
                xy = PointHook(Point(-100nm, -100nm), 0),
                q2 = PointHook(Point(100μm, 0μm), π)
            ),
            name="bq",
            jj_width=300nm
        )

        xyline = TestCompVariant(;
            hooks=(
                qubit=PointHook(Point(0nm, 0nm), π / 2),
                in=PointHook(Point(0nm, 100nm), -π / 2)
            ),
            name="xy",
            width=1μm
        )

        zline = TestCompVariant(;
            hooks=(qubit=PointHook(Point(100nm, 0nm), π), in=PointHook(Point(0nm, 0nm), 0)),
            name="z",
            height=2μm
        )

        bqnode = add_node!(g, bq)
        fuse!(g, bqnode => :xy, xyline => :qubit)
        fuse!(g, bqnode => :z, zline => :qubit)
        SimpleCC = BasicCompositeComponent(g)
        @test SimpleCC[1].parameters == bq.parameters
        simple_cc_2 = SimpleCC("scc2", ((;), (; width=2μm), (;)); _3_height=3μm)

        @test default_parameters(SimpleCC).sub_parameters[1] ==
              parameters(components(simple_cc_2)[1])
        @test parameters(components(simple_cc_2)[2]).width == 2μm
        @test name(components(simple_cc_2)[2]) == name(xyline)
        @test hooks(simple_cc_2, 3, :in).p ≈ Point(0μm, -0.1μm)
        @test in_direction(hooks(simple_cc_2, 3, :in)) == 90°

        composite_node = fuse!(g, bqnode => :q2, simple_cc_2 => :_1_q2)
        @test g.scc2.bq.jj_width == bq.jj_width

        floorplan = plan(g; log_dir=nothing)
        check!(floorplan)
        @test hooks(floorplan, composite_node)._1_xy.p ≈ Point(200.1μm, 0.100μm)
        @test origin(floorplan, composite_node) ≈ Point(200μm, 0μm)
        @test center(floorplan, composite_node, composite_node[1]) ≈ Point(200μm, 0μm)
        @test bounds(floorplan, composite_node, composite_node[2]) ≈
              Rectangle(0μm, 0μm) + Point(200.1μm, 0.1μm)

        build!(floorplan)
        cs = floorplan.coordinate_system

        ### Flattening
        g2 = copy(g)
        g2 = SchematicDrivenLayout.flatten(g2, depth=1)
        floorplan2 = plan(g2; log_dir=nothing)
        check!(floorplan2)
        @test length(components(g2)) == 6
        @test allunique(components(g2)) == false
        @test length(SchematicDrivenLayout.edges(g2)) == 5
        @test origin(floorplan2, find_components(c -> name(c) == "bq", g2)[2]) ≈
              Point(200μm, 0μm)
        @test origin(floorplan2, find_components(c -> name(c) == "xy", g2)[2]) ≈
              Point(200.1μm, 0.1μm)
        @test origin(floorplan2, find_components(c -> name(c) == "z", g2)[2]) ≈
              Point(200.0μm, 0.1μm)
        build!(floorplan2)
        cs2 = floorplan2.coordinate_system

        ### Nesting
        composite_node2 = fuse!(g, composite_node => :_2_qubit, simple_cc_2 => :_2_qubit)
        nested_cc = BasicCompositeComponent(g)
        # composite => :_2_in is at Point(200.1, 0.1) + Point(0, -0.1), orientation -π/2
        # nested_cc => :_4__2_in is also at Point(200.1, 0), orientation -π/2
        nested_node = fuse!(g, composite_node => :_2_in, nested_cc => :_4__2_in)
        g3 = copy(g)
        @test length(find_components(TestCompVariant, g3)) == 18
        @test length(find_components(TestCompVariant, g3, depth=2)) == 12
        # There are two unique components named "z" appearing a combined 4 times up to depth 2
        @test length(find_components(c -> name(c) == "z", g3, depth=2)) == 4
        @test length(
            unique(component.(g3[find_components(c -> name(c) == "z", g3, depth=2)]))
        ) == 2

        g3_flat = SchematicDrivenLayout.flatten(g3)
        g3 = SchematicDrivenLayout.flatten(g3, depth=1)
        @test length(components(g3)) == 14
        g3 = SchematicDrivenLayout.flatten(g3, depth=1)
        @test length(components(g3)) == 18
        @test length(unique(components(g3))) == 5
        @test g3.graph == g3_flat.graph
        @test !(g3.graph === g3_flat.graph)
        floorplan3 = plan(g3; log_dir=nothing)

        @test origin(floorplan3, find_components(c -> name(c)[1:1] == "z", g3)[end]) ≈
              Point(200.2μm, 0.1μm)
        # Make sure that cells for unique "z" have unique names when rendering
        c = Cell(floorplan3.coordinate_system)
        a = []
        traverse!(a, c)
        @test length(findall(x -> name(last(x)) == DeviceLayout.coordsys_name(zline), a)) ==
              2

        ### Full composite component
        pa = Path(Point(0μm, 0μm), name="pz")
        pa.metadata = BASE_NEGATIVE
        straight!(pa, 100μm, Paths.SimpleCPW(10μm, 6μm))
        attach!(pa, sref(CoordinateSystem("empty", nm)), 50μm)
        @compdef struct Test2BQ <: AbstractCompositeComponent{typeof(1.0nm)}
            name::String = "bqbq"
            jj_width = 250nm
        end

        function SchematicDrivenLayout._build_subcomponents(comp::Test2BQ)
            params = parameters(comp)
            return (
                TestCompVariant(
                    hooks=(
                        z  = PointHook(Point(0nm, 0nm), π / 2),
                        xy = PointHook(Point(-100nm, -100nm), 0),
                        q2 = PointHook(Point(100μm, 0μm), π)
                    ),
                    name="bq1",
                    jj_width=params.jj_width
                ),
                TestCompVariant(
                    hooks=(
                        z  = PointHook(Point(0nm, 0nm), π / 2),
                        xy = PointHook(Point(-100nm, -100nm), 0),
                        q2 = PointHook(Point(100μm, 0μm), π)
                    ),
                    name="bq2",
                    jj_width=2 * params.jj_width
                ),
                pa
            )
        end

        function SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            comp::Test2BQ,
            subcomps::NamedTuple
        )
            n1 = add_node!(g, subcomps.bq1)
            fuse!(g, n1 => :q2, subcomps.bq2 => :q2)
            fuse!(g, n1 => :z, subcomps.pz => :p0)
            return g
        end
        SchematicDrivenLayout.map_hooks(::Type{Test2BQ}) = Dict{Pair{Int, Symbol}, Symbol}()

        bq2 = Test2BQ(; name="2bq", jj_width=200nm)
        @test SchematicDrivenLayout.decompose_hookname(bq2, :_1_xy) == (1 => :xy)
        @test_throws "No hook" SchematicDrivenLayout.decompose_hookname(bq2, :_1_q)

        SchematicDrivenLayout.map_hooks(::Type{Test2BQ}) =
            Dict((1 => :xy) => :xy1, (2 => :xy) => :xy2, (1 => :z) => :z1, (2 => :z) => :z2)
        empty!(bq2._hooks)

        @test hooks(bq2, "bq1", :xy) == hooks(bq2, 1 => :xy) # using subcomp name or index=>hsym
        @test keys(SchematicDrivenLayout.subcomponents(bq2)) == (:bq1, :bq2, :pz)
        # test creating Cell without build uses path's coordsys_name
        c = Cell(geometry(bq2); map_meta=_ -> GDSMeta())
        a = []
        traverse!(a, c)
        @test DeviceLayout.coordsys_name(pa) != name(pa)
        @test isempty(findall(x -> name(last(x)) == name(pa), a))

        g = SchematicGraph("comp")
        bq2_node = add_node!(g, bq2)
        floorplan = plan(g; log_dir=nothing)
        check!(floorplan)
        @test hooks(floorplan, bq2_node).xy2.p ≈ Point(200.1μm, 0.1μm)
        build!(floorplan)

        ### Nested full CompositeComponent
        @compdef struct TestWrapper <: AbstractCompositeComponent{typeof(1.0nm)}
            name::String = "wrap"
            jj_width = 250nm
        end
        SchematicDrivenLayout._build_subcomponents(comp::TestWrapper) =
            (Test2BQ(; name="bqbq", jj_width=comp.jj_width),)
        function SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            comp::TestWrapper,
            subcomps::NamedTuple
        )
            return add_node!(g, subcomps.bqbq)
        end
        c = TestWrapper(jj_width=200nm)
        @test component(graph(c)[1]).jj_width == 200nm
        @test component(graph(component(graph(c)[1]))[1]).jj_width == 200nm

        @composite_variant TestWrapperVariant TestWrapper new_defaults = (; jj_width=200nm)
        @test component(graph(TestWrapperVariant())[1]).jj_width == 200nm

        ### No reordering of nodes or changing root of rendering tree
        g = SchematicGraph("spacers")
        n1 = add_node!(g, Spacer(name="first", p1=Point(10μm, 0μm)))
        n2 = fuse!(
            g,
            n1 => :p1_east,
            Spacer(name="second", p1=Point(10μm, 0μm)) => :p1_south
        )
        bcc = BasicCompositeComponent(g)
        g2 = SchematicGraph("test")
        bccn = add_node!(g2, bcc)
        fuse!(
            g2,
            bccn => :_2_p0_north,
            Spacer(name="third", p1=Point(10μm, 0μm)) => :p1_south
        )
        g3 = flatten(g2)
        floorplan3 = plan(g3; log_dir=nothing)
        @test name.(components(g3)) == ["first", "second", "third"]
        @test origin(floorplan3, g3[2]) ≈ Point(10μm, 10μm)
        @test origin(floorplan3, g3[3]) ≈ Point(10μm, 20μm)
        ### Copies of composite component
        g = SchematicGraph("comp")
        add_node!(g, Test2BQ(; name="2bq", jj_width=200nm))
        # Second component will get unique graph name and node id despite same name parameter
        add_node!(g, Test2BQ(; name="2bq", jj_width=300nm))
        floorplan = plan(g; log_dir=nothing)
        check!(floorplan)
        build!(floorplan)
        # Subnode coordinate systems of composite component should also have unique names
        c = Cell("test_no_duplicate_names", nm)
        render!(c, floorplan.coordinate_system; map_meta=m -> GDSMeta())
        @test_nowarn save(joinpath(tdir, "test_duplicates.gds"), c)

        ## Composite component having multiple instances of a subcomponent
        ## that is also a composite component with a named component in it
        pa = Path(; name="path")
        g = SchematicGraph("pathgraph")
        add_node!(g, pa)
        sub_cc = BasicCompositeComponent(g)
        pa = Path(; name="path")
        g = SchematicGraph("pathgraph")
        add_node!(g, pa)
        sub_cc2 = BasicCompositeComponent(g)
        g2 = SchematicGraph("supergraph")
        add_node!(g2, sub_cc)
        add_node!(g2, sub_cc2)
        super_cc = BasicCompositeComponent(g2)
        c = Cell("test_no_duplicate_names", nm)
        render!(c, super_cc; map_meta=m -> GDSMeta())
        @test_nowarn save(joinpath(tdir, "test_duplicates.gds"), c)
    end

    @testset "GDSComponent" begin
        c = Cell("c", nm)
        render!(c, Rectangle(1μm, 2μm), GDSMeta(1))
        render!(c, centered(Rectangle(4μm, 5μm)), GDSMeta(2))
        save(joinpath(tdir, "gdstest.gds"), c)
        comp = GDSComponent(joinpath(tdir, "gdstest.gds"), "c")
        cs = geometry(comp)
        c2 = Cell(cs, nm)
        c3 = cell(c2.refs[1])
        @test c3.elements[1] == Polygon(points(Rectangle(1000nm, 2000nm)))
        @test c3.element_metadata[1] == GDSMeta(1)
        @test c3.elements[2] == Polygon(points(centered(Rectangle(4000nm, 5000nm))))
        @test c3.element_metadata[2] == GDSMeta(2)
    end

    @testset "Halos" begin
        # Simple rectangle
        cs = CoordinateSystem("poly", nm)
        render!(cs, Rectangle(5μm, 10μm), BASE_NEGATIVE)
        render!(cs, Rectangle(10μm, 5μm), BASE_POSITIVE)
        halo_cs = halo(cs, 4μm; only_layers=[:base_negative])
        @test Set(points(halo_cs.elements[1])) ==
              Set(points(Rectangle(Point(-4000.0, -4000.0)nm, Point(9000.0, 14000.0)nm)))
        @test halo_cs.element_metadata[1] == BASE_NEGATIVE
        @test length(halo_cs.elements) == 1

        # Issue #90: Component without only_layers
        comp = BasicComponent(cs)
        comp_halo_cs = halo(comp, 1μm)
        @test length(comp_halo_cs.elements) == 2

        # Mixed layername + metadata rule
        cs = CoordinateSystem("poly", nm)
        render!(cs, Rectangle(5μm, 10μm), BASE_NEGATIVE)
        render!(cs, Rectangle(10μm, 5μm), facing(BASE_NEGATIVE))
        render!(cs, Rectangle(5μm, 10μm), BASE_POSITIVE)
        render!(cs, Rectangle(10μm, 5μm), facing(BASE_POSITIVE))
        halo_cs = halo(cs, 4μm; only_layers=[:base_negative, BASE_POSITIVE])
        @test halo_cs.element_metadata ==
              [BASE_NEGATIVE, facing(BASE_NEGATIVE), BASE_POSITIVE]
        @test length(halo_cs.elements) == 3

        # Merging polygon halos
        cs = CoordinateSystem("poly", nm)
        render!(cs, Rectangle(1μm, 1μm), BASE_NEGATIVE)
        render!(cs, Rectangle(1μm, 1μm) + Point(2, 0)μm, BASE_NEGATIVE)
        halo_cs = halo(cs, 1μm; only_layers=[:base_negative])
        @test Set(points(halo_cs.elements[1])) ==
              Set(points(Rectangle(Point(-1000.0, -1000.0)nm, Point(4000.0, 2000.0)nm)))
        @test halo_cs.element_metadata[1] == BASE_NEGATIVE
        @test length(halo_cs.elements) == 1

        # Path
        pa = Path(0μm, 0μm)
        straight!(pa, 100μm, Paths.SimpleCPW(10μm, 6μm))
        cs = CoordinateSystem("path", nm)
        render!(cs, pa, BASE_NEGATIVE)
        halo_cs = halo(cs, 1μm; only_layers=[:base_negative])
        halo_path = structure(halo_cs.refs[1])
        @test pathlength(halo_path) ≈ 102μm
        @test Paths.extent(style(halo_path[1]), 50μm) == 12μm
        @test halo_path.metadata == BASE_NEGATIVE
    end

    @testset "Autofill" begin
        g = SchematicGraph("autofill_test")
        cs_0 = CoordinateSystem("c0", nm)
        render!(cs_0, centered(Rectangle(10μm, 10μm)), SemanticMeta(:base_negative))
        add_node!(g, BasicComponent(cs_0))

        floorplan = plan(g; log_dir=nothing)
        check!(floorplan)

        addref!(floorplan, cs_0, Point(200μm, 0μm))

        autofill!(
            floorplan,
            cs_0,
            (-1:0.2:1)mm,
            (-1:0.2:1)mm,
            make_halo(50µm, only_layers=[:base_negative])
        )

        autofill!(
            floorplan,
            cs_0,
            (-1:0.05:1)mm,
            (-1:0.05:1)mm,
            make_halo(80µm, only_layers=[:base_negative])
        )

        build!(floorplan)
        target = ArtworkTarget(ProcessTechnology((; base_negative=GDSMeta()), (;)))
        c = flatten(Cell(floorplan, target))
        @test length(c.elements) == 841
    end

    @testset "Crossovers" begin
        g = SchematicGraph("crossovers")
        p = Path(nm2nm, metadata=BASE_NEGATIVE) # Won't work if Unitful.nm is mixed with RouteComponent's nm2nm
        turn!(p, 180°, 500μm, Paths.SimpleCPW(10μm, 6μm))
        straight!(p, 1mm)
        turn!(p, -180°, 200μm)
        pn = add_node!(g, p)
        p2 = Path(nm2nm, metadata=BASE_NEGATIVE)
        straight!(p2, 100μm, Paths.SimpleCPW(10μm, 6μm))
        pn2 = fuse!(g, pn => :p1, p2 => :p0)
        route!(
            g,
            Paths.StraightAnd90(max_bend_radius=200μm),
            pn2 => :p1,
            pn => :p0,
            Paths.SimpleCPW(10μm, 6μm),
            BASE_NEGATIVE
        )
        sch = plan(g; log_dir=nothing)
        xsty = Intersect.AirBridge(
            crossing_gap=5μm,
            foot_gap=2μm,
            foot_length=4μm,
            extent_gap=2μm,
            scaffold_gap=5μm,
            scaffold_meta=GDSMeta(1),
            air_bridge_meta=GDSMeta(2)
        )
        SchematicDrivenLayout.crossovers!(sch, xsty)
        @test sch.graph[3].component isa Path # was replaced with concrete Path in crossovers!
    end

    @testset "Filter params" begin
        @compdef struct MyCompositeComponent <: CompositeComponent
            templates = (;
                subcomp1=MySubComponent(; name="subcomp1"),
                subcomp2=MySubComponent(; name="subcomp2")
            )
            subcomp1_width = 2mm
            length = 2mm
        end

        @compdef struct MySubComponent <: Component
            width = 1mm
            length = 1mm
        end

        function SchematicDrivenLayout._build_subcomponents(cc::MyCompositeComponent)
            shared_params = filter_parameters(MySubComponent, cc) # Matching with no prefix: (; length=...)
            subcomp1_overrides = filter_parameters(cc.templates.subcomp1, cc) # Matching with prefix: (; width=...)
            @component subcomp1 =
                cc.templates.subcomp1(; subcomp1_overrides..., shared_params...)
            @component subcomp2 = cc.templates.subcomp2(; shared_params...)
            return (subcomp1, subcomp2)
        end

        function SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            cc::MyCompositeComponent,
            subcomps::NamedTuple
        )
            add_node!(g, subcomps.subcomp1)
            return add_node!(g, subcomps.subcomp2)
        end

        @component subcomp1 = MySubComponent(; width=3mm, length=3mm) # Both overridden
        @component subcomp2 = MySubComponent(; width=3mm, length=3mm) # Only length overridden

        cc = MyCompositeComponent(; templates=(; subcomp1, subcomp2))
        @test SchematicDrivenLayout.filter_parameters(MySubComponent, cc) ==
              Dict(:length => 2mm)
        @test SchematicDrivenLayout.filter_parameters(
            MySubComponent,
            cc,
            except=[:length]
        ) == Dict()
        @test SchematicDrivenLayout.filter_parameters(subcomp1, cc) == Dict(:width => 2mm)
        @test_logs (:warn, r"No shared parameters") SchematicDrivenLayout.filter_parameters(
            Spacer,
            cc
        )
        @test_logs (:warn, r"No parameters") SchematicDrivenLayout.filter_parameters(
            Spacer(),
            cc
        )

        @test SchematicDrivenLayout.subcomponents(cc).subcomp1.width == 2mm
        @test SchematicDrivenLayout.subcomponents(cc).subcomp2.width == 3mm
        @test SchematicDrivenLayout.subcomponents(cc).subcomp1.length == 2mm
        @test SchematicDrivenLayout.subcomponents(cc).subcomp2.length == 2mm
    end

    @testset "SolidModels" begin
        @test SchematicDrivenLayout.level_z.(0:3) == [-525μm, 0μm, 5μm, 530μm]
        @test SchematicDrivenLayout.level_z.(
            0:7,
            t_chips=[100, 200, 300, 400],
            t_gaps=[5, 10, 15]
        ) == [-100, 0, 5, 205, 215, 515, 530, 930]

        g = SchematicGraph("test")
        cs_0 = CoordinateSystem("c0", nm)
        render!(cs_0, centered(Rectangle(100μm, 100μm)), SemanticMeta(:base_negative))
        render!(cs_0, centered(Rectangle(5mm, 5mm)), SemanticMeta(:writeable_area))
        render!(cs_0, centered(Rectangle(5mm, 5mm)), SemanticMeta(:chip_outline))

        render!(
            cs_0,
            centered(Rectangle(50μm, 50μm)),
            SemanticMeta(:base_negative, level=2)
        )
        render!(
            cs_0,
            centered(Rectangle(0.8mm, 0.8mm)),
            SemanticMeta(:writeable_area, level=2)
        )
        render!(
            cs_0,
            centered(Rectangle(0.8mm, 0.8mm)),
            SemanticMeta(:chip_outline, level=2)
        )

        bridge_cs = CoordinateSystem("bridge", nm)
        place!(bridge_cs, centered(Rectangle(20μm, 40μm)), :scaffold)
        place!(bridge_cs, centered(Rectangle(16μm, 60μm)), :air_bridge)

        pa = Path(150μm, 0μm)
        straight!(pa, 325μm, Paths.SimpleCPW(10μm, 6μm))
        turn!(pa, 180°, 50μm)
        straight!(pa, 325μm)
        attach!(pa, sref(bridge_cs), (50:50:250)μm)
        turn!(pa, -180°, 50μm)
        straight!(pa, 250μm, Paths.TaperCPW(10μm, 6μm, 2μm, 1μm))
        place!(cs_0, pa, SemanticMeta(:base_negative))
        cs_1 = CoordinateSystem("c1", nm)
        render!(cs_1, Rectangle(10μm, 10μm) + Point(100μm, 100μm), SemanticMeta(:port))
        cs_2 = CoordinateSystem("c2", nm)
        render!(
            cs_2,
            Rectangle(10μm, 10μm) + Point(100μm, 100μm),
            SemanticMeta(:port, level=2)
        )

        add_node!(g, BasicComponent(cs_0))
        add_node!(g, BasicComponent(cs_1))
        # Test composite component with port
        g2 = SchematicGraph("c2")
        add_node!(g2, BasicComponent(cs_2))
        c2 = BasicCompositeComponent(g2)
        add_node!(g, c2)

        floorplan = plan(g; log_dir=nothing)

        render!(
            floorplan.coordinate_system,
            centered(Rectangle(1mm, 1mm)),
            SemanticMeta(:simulated_area)
        )
        check!(floorplan)

        tech = ProcessTechnology(
            (;
                base_negative=GDSMeta(),
                simulated_area=GDSMeta(2),
                writeable_area=GDSMeta(3)
            ),
            (;
                height=(; simulated_area=-1mm, fake_layer=[1μm, 2μm]),
                thickness=(; simulated_area=2mm, chip_outline=[500μm, 400μm]),
                chip_thicknesses=[500μm, 400μm],
                flipchip_gaps=[150μm]
            )
        )
        @test SchematicDrivenLayout.layer_thickness(
            tech,
            SemanticMeta(:chip_outline, level=2)
        ) == 400μm
        @test SchematicDrivenLayout.layer_height(
            tech,
            SemanticMeta(:fake_layer, level=2)
        ) == 2μm
        target = SchematicDrivenLayout.SolidModelTarget(
            tech;
            bounding_layers=[:simulated_area],
            substrate_layers=[:chip_outline],
            levelwise_layers=[:chip_outline],
            indexed_layers=[:port],
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
                ),
                SolidModels.staple_bridge_postrendering(
                    base="scaffold",
                    bridge="air_bridge",
                    bridge_height=10μm
                )...,
                ("conductor", SolidModels.union_geom!, ("base_metal", "bridge_metal"))
            ]
        )

        sm = SolidModel("test", overwrite=true)
        render!(sm, floorplan, target)

        # Reduce the noise in the REPL
        SolidModels.gmsh.option.setNumber("General.Verbosity", 0)
        @test_nowarn SolidModels.gmsh.model.mesh.generate(3) # runs without error
        bbox = SolidModels.bounds3d(SolidModels.gmsh.model.getEntities(2))
        # Are all boundaries within simulation volume?
        limits = ustrip.(SolidModels.STP_UNIT, [-0.5mm, -0.5mm, -1mm, 0.5mm, 0.5mm, 1mm])
        @test all(isapprox.(bbox, limits, atol=1e-6))
        # Test port indexing
        @test all(name.(component.(floorplan.index_dict[:port])) .== ["c1", "c2"])
        bbox_allports = SolidModels.bounds3d(sm["port", 2])
        bbox_port1 = SolidModels.bounds3d(sm["port_1", 2])
        b1 = bounds(cs_1)
        bbox_port2 = SolidModels.bounds3d(sm["port_2", 2])
        b2 = bounds(cs_2)
        @test all(
            isapprox.(
                bbox_port1,
                ustrip.(
                    SolidModels.STP_UNIT,
                    [b1.ll.x, b1.ll.y, 0μm, b1.ur.x, b1.ur.y, 0μm]
                ),
                atol=1e-6
            )
        )
        @test all(
            isapprox.(
                bbox_port2,
                ustrip.(
                    SolidModels.STP_UNIT,
                    [
                        b2.ll.x,
                        b2.ll.y,
                        tech.parameters.flipchip_gaps[1],
                        b2.ur.x,
                        b2.ur.y,
                        tech.parameters.flipchip_gaps[1]
                    ]
                ),
                atol=1e-6
            )
        )
        @test all(
            isapprox.(
                bbox_allports,
                ustrip.(
                    SolidModels.STP_UNIT,
                    [
                        b1.ll.x,
                        b1.ll.y,
                        0μm,
                        b1.ur.x,
                        b1.ur.y,
                        tech.parameters.flipchip_gaps[1]
                    ]
                ),
                atol=1e-6
            )
        )
    end
end
