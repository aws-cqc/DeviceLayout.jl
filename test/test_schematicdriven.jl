@testitem "Schematic-Driven Layout" setup = [CommonTestSetup, QuietGmshSetup] begin
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

    struct UncachedTargetComponent <: AbstractComponent{typeof(1.0nm)}
        name::String
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
    quiet_test_output() do
        @eval function SchematicDrivenLayout._geometry!(
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
            arrow =
                attach!(g, pan, CutoutFlipchipArrow() => :tip, 50μm; i=1, location=:left)
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
        use_test_matching_hook = Ref(true)
        use_test_matching_hooks = Ref(false)
        function SchematicDrivenLayout.matching_hook(
            t1::TestComponent,
            s::Symbol,
            ::TestComponent
        )
            return use_test_matching_hook[] ? :z :
                   SchematicDrivenLayout.matching_hook(t1, s, Spacer())
        end
        function SchematicDrivenLayout.matching_hooks(t1::TestComponent, ::TestComponent)
            return use_test_matching_hooks[] ? (:xy, :qubit) :
                   SchematicDrivenLayout.matching_hooks(t1, Spacer())
        end
        bq_node2 = fuse!(g2, template_node2 => :bq, bq)
        z_node2 = fuse!(g2, bq_node2, zline => :qubit)
        @test_throws "No matching hook" fuse!(g2, bq_node2, xyline)
        use_test_matching_hooks[] = true
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
        use_test_matching_hook[] = false
        use_test_matching_hooks[] = false

        # `rem_node!` drops the node from `nodes` and from the name lookup. `node_dict` is
        # keyed by `Symbol`, as `add_node!` inserts it, so deleting with the node's `String`
        # id deletes nothing: the removed node stays reachable as `g.<id>` and every later
        # use of it fails obscurely, since `indexof` then returns `nothing`.
        @testset "Remove" begin
            g3 = SchematicGraph("test_remove")
            keep = add_node!(g3, template)
            drop = add_node!(g3, bq)
            @test Symbol(drop.id) in keys(g3.node_dict)
            @test rem_node!(g3, drop) === drop
            @test nodes(g3) == [keep]
            @test !(Symbol(drop.id) in keys(g3.node_dict))
            @test Symbol(keep.id) in keys(g3.node_dict)
            @test getproperty(g3, Symbol(keep.id)) === keep
        end

        # `add_node!` uses `base_id` literally: a name ending in `_<n>` is not read as a counter
        # (`uniquename("x_3_1", '_')` would give `"x3_1"`), and only a re-used id gets a suffix.
        @testset "Node ids" begin
            g4 = SchematicGraph("test_node_ids")
            @test add_node!(g4, Spacer(; name="x_3_1")).id == "x_3_1"
            @test add_node!(g4, Spacer(; name="x_3_1")).id == "x_3_1_2"
            @test add_node!(g4, Spacer(; name="x_3_2")).id == "x_3_2"
            @test add_node!(g4, Spacer(; name="x_3")).id == "x_3"
            @test add_node!(g4, Spacer(; name="x"); base_id="y_1").id == "y_1"
        end

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
            logger = TestLogger()
            floorplan = with_logger(logger) do
                return plan(g; log_dir=log_dir)
            end
            check!(floorplan)
            @test_throws "Encountered errors" build!(floorplan)
            build!(floorplan; strict=:no)
            @test SchematicDrivenLayout.max_level_logged(floorplan, :build) == Logging.Error
            @test contains(
                read(floorplan.logger.logname, String),
                "Could not automatically route"
            )
            @test all(logger.logs) do log
                return log.level < Logging.Warn || (
                    log.level == Logging.Error &&
                    occursin("Could not automatically route", log.message)
                )
            end
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
                # Plan inside `@test_logs`, since the schematic logger writes to the logger
                # that is current when the schematic is planned
                floorplan =
                    @test_logs (:error, r"Invalid rotation") (:error, r"failed design rule") begin
                        fp = plan(g; log_dir=nothing)
                        @test fp.checked[] == false
                        @test_throws ErrorException check!(fp) # check! should fail
                        fp
                    end
                @test floorplan.checked[] == false
                @test !(@test_logs (:error, r"Invalid rotation.*must be one of") SchematicDrivenLayout.rotations_valid(
                    floorplan
                ))
                @test_throws ErrorException build!(floorplan) # build should fail too

                # Test within composite component
                composite = BasicCompositeComponent(g)
                g = SchematicGraph("test_g_4")
                add_node!(g, composite)
                # check! should fail even though the problem is hidden inside composite
                @test_logs (:error, r"Invalid rotation") (:error, r"failed design rule") begin
                    floorplan = plan(g; log_dir=nothing)
                    @test_throws ErrorException check!(floorplan)
                end

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
                floorplan =
                    @test_logs (:error, r"Invalid rotation") (:error, r"failed design rule") begin
                        fp = plan(g; log_dir=nothing)
                        # node 4 is the corner of the L
                        fp[nodes(g)[4]].xrefl = true
                        @test fp.checked[] == false
                        @test_throws ErrorException check!(fp) # check! should fail
                        fp
                    end
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
                allowed_cycle_log =
                    log ->
                        log.level == Logging.Error && (
                            occursin("overconstrained", log.message) ||
                            occursin("Failed to plan", log.message)
                        )
                @test_throws "Encountered errors" with_test_logger(
                    allowed_cycle_log;
                    required=allowed_cycle_log
                ) do
                    return plan(g; log_dir=nothing)
                end
                log_dir = mktempdir()
                floorplan =
                    with_test_logger(allowed_cycle_log; required=allowed_cycle_log) do
                        return plan(g; strict=:no, log_dir=log_dir)
                    end
                @test SchematicDrivenLayout.max_level_logged(floorplan, :plan) ==
                      Logging.Error
                @test contains(read(floorplan.logger.logname, String), "is overconstrained")
            end
        end
    end

    @testset "Cell render geometry recovery" begin
        @compdef struct FallibleComponent <: Component
            name = "fallible"
            fail::Bool = false
        end
        function SchematicDrivenLayout._geometry!(
            cs::CoordinateSystem,
            c::FallibleComponent
        )
            c.fail && error("geometry failure")
            return place!(cs, centered(Rectangle(10μm, 10μm)), BASE_NEGATIVE)
        end
        SchematicDrivenLayout.hooks(::FallibleComponent) =
            (; origin=PointHook(0μm, 0μm, 0°))
        target = ArtworkTarget(ProcessTechnology((; base_negative=GDSMeta()), (;)))

        # Plan under a TestLogger so the schematic logger tees render logs into it.
        function recovery_schematic(logger)
            g = SchematicGraph("recovery")
            add_node!(g, FallibleComponent(name="good"))
            add_node!(g, FallibleComponent(name="bad", fail=true))
            sch = with_logger(() -> plan(g; log_dir=nothing), logger)
            check!(sch)
            return sch
        end

        logger = TestLogger()
        sch = recovery_schematic(logger)
        cell = Cell("recovered", nm)
        @test render!(cell, sch, target; strict=:no) === cell
        @test length(elements(flatten(cell))) == 1
        @test SchematicDrivenLayout.max_level_logged(sch, :render) == Logging.Error
        @test count(log -> log.level == Logging.Error, logger.logs) == 1

        sch = recovery_schematic(TestLogger())
        @test_throws ErrorException render!(Cell("strict", nm), sch, target)
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
        @test_logs (:warn, r"Target technology") render!(
            cell,
            cs,
            ArtworkTarget(tech; levels=[1])
        ) # meta, undef_meta, GDSMeta(2,2)
        @test cell.element_metadata == [GDSMeta(), GDSMeta(), GDSMeta(2, 2)]
        cell = Cell("test", nm)
        render!(cell, cs, ArtworkTarget(tech; levels=[2])) # facing(meta), (:GDS2_2,2,2), GDSMeta(2,2)
        @test cell.element_metadata == [GDSMeta(), GDSMeta(2, 2), GDSMeta(2, 2)]
        cell = Cell("test", nm)
        @test_logs (:warn, r"Target technology") render!(
            cell,
            cs,
            ArtworkTarget(tech; levels=[1, 2], indexed_layers=[:GDS2_2])
        )
        @test cell.element_metadata ==
              [GDSMeta(), GDSMeta(300), GDSMeta(302, 4), GDSMeta(), GDSMeta(2, 2)]
        @test SchematicDrivenLayout.map_layer(ArtworkTarget(tech), SemanticMeta(:GDS2)) ==
              GDSMeta(2)

        # Manual map_meta_dict override
        target = ArtworkTarget(tech; levels=[1])
        target.map_meta_dict[meta] = nothing
        target.map_meta_dict[GDSMeta(2, 2)] = GDSMeta(3, 3)
        cell = Cell("test", nm)
        @test_logs (:warn, r"Target technology") render!(cell, cs, target) # undef_meta, GDSMeta(2,2)
        @test cell.element_metadata == [GDSMeta(), GDSMeta(3, 3)]

        @testset "Target style helpers" begin
            artwork = ArtworkTarget(tech)
            simulation = SimulationTarget(tech)
            solidmodel = ArtworkTarget(tech, rendering_options=(; solidmodel=true))
            helper_cases = (
                (not_simulated!, artwork, simulation),
                (only_simulated!, simulation, artwork),
                (not_solidmodel!, artwork, solidmodel),
                (only_solidmodel!, solidmodel, artwork)
            )
            function nrendered(cs, target)
                logger = TestLogger()
                cell = with_logger(logger) do
                    return flatten(Cell(cs, nm, target))
                end
                @test all(logger.logs) do log
                    return log.level == Logging.Warn && occursin(
                        "Target technology does not have a mapping",
                        log.message
                    )
                end
                return length(elements(cell))
            end

            @testset "Coordinate-system references" begin
                arr!(parent, child) = addarr!(
                    parent,
                    child,
                    Point(0μm, 0μm);
                    dc=Point(20μm, 0μm),
                    nc=2,
                    dr=Point(0μm, 20μm),
                    nr=2
                )
                function refparent(add!)
                    child = CoordinateSystem("child", nm)
                    render!(child, rect, meta)
                    parent = CoordinateSystem("parent", nm)
                    add!(parent, child)
                    return parent
                end

                for (add!, count) in ((addref!, 1), (arr!, 4))
                    for (f!, visible_target, hidden_target) in helper_cases
                        parent = refparent(add!)
                        @test f!(parent) === parent
                        @test nrendered(parent, visible_target) == count
                        @test nrendered(parent, hidden_target) == 0
                    end
                end

                ref = only(refs(refparent(addref!)))
                @test not_simulated!(ref) === ref
            end

            @testset "Identical styles are idempotent" begin
                for (f!, _, _) in helper_cases
                    styled_cs = CoordinateSystem("styled", nm)
                    place!(styled_cs, rect, meta)
                    f!(styled_cs)
                    styled_ent = only(elements(styled_cs))
                    f!(styled_cs)
                    @test only(elements(styled_cs)) === styled_ent
                end
            end

            @testset "Component traversal continues after a warning" begin
                cached = SchematicDrivenLayout.ArrowAnnotation(meta=meta)
                trailing = CoordinateSystem("trailing", nm)
                place!(trailing, rect, meta)
                parent = CoordinateSystem("component_parent", nm)
                addref!(parent, cached)
                addref!(parent, UncachedTargetComponent("uncached"))
                addref!(parent, trailing)

                result = @test_logs (:warn, r"uncached component uncached") not_simulated!(
                    parent
                )
                @test result === parent
                @test only(elements(geometry(cached))) isa DeviceLayout.StyledEntity
                @test only(elements(trailing)) isa DeviceLayout.StyledEntity
            end

            @testset "Path overloads and references" begin
                child = CoordinateSystem("attached", nm)
                place!(child, rect, meta)
                pa = Path(Point(0μm, 0μm))
                straight!(pa, 10μm, Paths.Trace(1μm))
                attach!(pa, sref(child), 5μm)

                for (f, (_, visible_target, hidden_target)) in zip(
                    (not_simulated, only_simulated, not_solidmodel, only_solidmodel),
                    helper_cases
                )
                    styled_path = CoordinateSystem("styled_path", nm)
                    place!(styled_path, f(pa), meta)
                    @test nrendered(styled_path, visible_target) == 1
                    @test nrendered(styled_path, hidden_target) == 0
                end

                parent = CoordinateSystem("pathparent", nm)
                addref!(parent, pa)
                not_simulated!(parent)
                cs_equiv = structure(only(refs(parent)))
                @test cs_equiv isa CoordinateSystem
                @test length(elements(cs_equiv)) == 1
                @test only(elements(cs_equiv)) isa DeviceLayout.StyledEntity
                @test DeviceLayout.unstyled(only(elements(cs_equiv))) isa Paths.Node
                @test structure(only(refs(cs_equiv))) === child
                @test only(elements(child)) isa DeviceLayout.StyledEntity

                path_ent = only(elements(cs_equiv))
                child_ent = only(elements(child))
                not_simulated!(cs_equiv)
                @test only(elements(cs_equiv)) === path_ent
                @test only(elements(child)) === child_ent
            end

            @testset "Array references attached to curved paths" begin
                child = CoordinateSystem("curved_attachment", nm)
                place!(child, Rectangle(4μm, 2μm), meta)
                attached = aref(
                    child,
                    Point(0μm, 0μm);
                    dc=Point(20μm, 0μm),
                    nc=2,
                    dr=Point(0μm, 20μm),
                    nr=2,
                    rot=30°
                )

                pa = Path(Point(0μm, 0μm); metadata=meta)
                straight!(pa, 100μm, Paths.SimpleTrace(10.0μm))
                turn!(pa, 90°, 50μm)
                attach!(pa, attached, 25μm; i=2)

                parent = CoordinateSystem("curved_path_parent", nm)
                addref!(parent, pa)
                styled = deepcopy(parent)
                not_simulated!(styled)

                rendered = flatten(Cell(styled, artwork))
                rendered_sim = flatten(Cell(styled, simulation))
                flattened = Cell(flatten(parent), artwork)
                @test length(flattened.elements) == 6
                @test length(rendered.elements) == length(flattened.elements)
                @test all(isapprox.(rendered.elements, flattened.elements))
                @test isempty(rendered_sim.elements)
            end

            @testset "Cell references preserve all contents" begin
                child = Cell("attached", nm)
                render!(child, rect, GDSMeta())
                cell = Cell("cell", nm)
                render!(cell, rect, GDSMeta())
                text!(cell, "label", Point(1μm, 2μm), GDSMeta(1, 2))
                addref!(cell, child, Point(5μm, 5μm))

                parent = CoordinateSystem("cellparent", nm)
                addref!(parent, cell, Point(5μm, 5μm))
                not_simulated!(parent)
                cs_equiv = structure(only(refs(parent)))
                unstyled = DeviceLayout.unstyled.(elements(cs_equiv))
                @test cs_equiv isa CoordinateSystem
                @test count(x -> x isa Polygon, unstyled) == 1
                @test count(x -> x isa Texts.Text, unstyled) == 1
                @test element_metadata(cs_equiv) == [GDSMeta(), GDSMeta(1, 2)]
                @test structure(only(refs(cs_equiv))) isa CoordinateSystem
                @test only(elements(structure(only(refs(cs_equiv))))) isa
                      DeviceLayout.StyledEntity
            end

            @testset "Path and Cell arrays preserve their shape" begin
                array_path = Path(Point(0μm, 0μm); metadata=meta)
                straight!(array_path, 10μm, Paths.SimpleTrace(1.0μm))
                array_cell = Cell("array_cell", nm)
                render!(array_cell, rect, GDSMeta())
                text!(array_cell, "label", Point(1μm, 2μm), GDSMeta(1, 2))

                for (geom, expected_counts) in ((array_path, (6, 0)), (array_cell, (6, 6)))
                    original = aref(
                        geom,
                        Point(3μm, 4μm);
                        dc=Point(20μm, 1μm),
                        nc=2,
                        dr=Point(2μm, 30μm),
                        nr=3,
                        xrefl=true,
                        mag=1.5,
                        rot=30°
                    )
                    parent = CoordinateSystem("array_parent", nm)
                    addref!(parent, original)
                    not_simulated!(parent)
                    replacement = only(refs(parent))

                    @test replacement isa ArrayReference
                    @test transformation(replacement) == transformation(original)
                    @test (
                        replacement.deltacol,
                        replacement.deltarow,
                        replacement.col,
                        replacement.row
                    ) == (original.deltacol, original.deltarow, original.col, original.row)

                    rendered = flatten(Cell(parent, nm, artwork))
                    @test (length(elements(rendered)), length(rendered.texts)) ==
                          expected_counts
                    if geom isa Cell
                        @test rendered.text_metadata == fill(GDSMeta(1, 2), 6)
                    end
                    hidden = flatten(Cell(parent, nm, simulation))
                    @test isempty(elements(hidden))
                    @test isempty(hidden.texts)
                end
            end

            @testset "Direct Path and Cell references require a parent" begin
                pa = Path(Point(0μm, 0μm))
                straight!(pa, 10μm, Paths.Trace(1μm))
                cell = Cell("direct_cell", nm)
                render!(cell, rect, GDSMeta())
                for (f!, _, _) in helper_cases, geom in (pa, cell)
                    @test_throws ArgumentError f!(sref(geom))
                end
            end
        end
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
        test_hook_map = Ref(Dict{Pair{Int, Symbol}, Symbol}())
        SchematicDrivenLayout.map_hooks(::Type{Test2BQ}) = test_hook_map[]

        bq2 = Test2BQ(; name="2bq", jj_width=200nm)
        @test SchematicDrivenLayout.decompose_hookname(bq2, :_1_xy) == (1 => :xy)
        @test_throws "No hook" SchematicDrivenLayout.decompose_hookname(bq2, :_1_q)

        test_hook_map[] =
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
        function SchematicDrivenLayout.map_hooks(comp::TestWrapper) # Define based on instance
            return Dict((1 => :xy1) => :xy1)
        end
        c = TestWrapper(jj_width=200nm)
        @test component(graph(c)[1]).jj_width == 200nm
        @test component(graph(component(graph(c)[1]))[1]).jj_width == 200nm

        @composite_variant TestWrapperVariant TestWrapper new_defaults = (; jj_width=200nm)
        @test component(graph(TestWrapperVariant())[1]).jj_width == 200nm
        @test hooks(TestWrapperVariant()).xy1.p == hooks(c).xy1.p # Uses base variant map_hooks

        # Vector-valued hooks of subcomponents
        @compdef struct VectorHookComposite <: AbstractCompositeComponent{typeof(1.0nm)}
            name::String = "vector_hooks"
        end
        SchematicDrivenLayout._build_subcomponents(comp::VectorHookComposite) = (
            GDSComponent(
                Cell("vh", nm),
                (; arr=[PointHook(0mm, i * 1mm, 90°) for i = 1:2])
            ),
        )
        SchematicDrivenLayout._graph!(
            g::SchematicGraph,
            comp::VectorHookComposite,
            subcomps::NamedTuple
        ) = add_node!(g, only(subcomps))
        @composite_variant VectorHookCompositeVariant VectorHookComposite
        @test hooks(VectorHookCompositeVariant()) == hooks(VectorHookComposite())

        # Variants reject unknown keyword arguments, as the base `@compdef` constructor does
        @test_throws MethodError TestComponent(; widht=1μm)
        @test_throws ArgumentError TestCompVariant(; widht=1μm)
        @test_throws ArgumentError create_component(TestCompVariant; widht=1μm)
        @test_throws MethodError TestWrapper(; jj_widht=200nm)
        @test_throws ArgumentError TestWrapperVariant(; jj_widht=200nm)
        @test_throws ArgumentError create_component(TestWrapperVariant; jj_widht=200nm)
        typo_ps = SchematicDrivenLayout.ParameterSet()
        typo_ps.components.variant.widht = 1μm
        @test_throws ArgumentError create_component(
            TestCompVariant,
            typo_ps,
            "components.variant"
        )
        # Variant-only parameters are still accepted
        @test parameters(TestCompVariant(; width=1μm)).width == 1μm
        @test parameters(create_component(TestWrapperVariant; jj_width=300nm)).jj_width ==
              300nm

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

    @testset "footprint_halo" begin
        import .SchematicDrivenLayout: footprint_halo
        # Component with geometry in two layers
        cs_fp = CoordinateSystem("fp_test", nm)
        render!(cs_fp, centered(Rectangle(10μm, 10μm)), BASE_NEGATIVE)
        sub_cs = CoordinateSystem("sub_cs", nm)
        render!(sub_cs, centered(Rectangle(8μm, 8μm)), BASE_POSITIVE)
        addref!(cs_fp, sub_cs)
        comp = BasicComponent(cs_fp)

        # footprint_halo replicates footprint halo across all layers
        fh = footprint_halo(comp, 2μm)
        @test length(fh.elements) == 2
        @test Set(fh.element_metadata) == Set([BASE_NEGATIVE, BASE_POSITIVE])

        # only_layers filtering
        fh_neg = footprint_halo(comp, 2μm; only_layers=[:base_negative])
        @test length(fh_neg.elements) == 1
        @test fh_neg.element_metadata[1] == BASE_NEGATIVE

        # inner_delta produces annular halo
        fh_annular = footprint_halo(comp, 4μm, 2μm)
        @test length(fh_annular.elements) == 2  # one per layer

        # memoized_halos prevents recomputation
        memo = Dict{DeviceLayout.GeometryStructure, DeviceLayout.GeometryStructure}()
        fh1 = footprint_halo(comp, 2μm; memoized_halos=memo)
        fh2 = footprint_halo(comp, 999μm; memoized_halos=memo)
        @test fh1 === fh2

        # ExampleStarIsland uses footprint_halo via its halo override
        isl = SchematicDrivenLayout.ExamplePDK.Transmons.ExampleStarIsland()
        isl_halo = halo(isl, 10μm)
        @test !isempty(isl_halo.elements)
        @test DeviceLayout.has_valid_footprint(isl)
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
        @test (@test_logs (:warn, r"No shared parameters") SchematicDrivenLayout.filter_parameters(
            MySubComponent,
            cc,
            except=[:length]
        )) == Dict()
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

    @testset "Dependent @compdef defaults" begin
        # Issue #20
        # Non-parametric path: defaults that reference earlier parameters
        @compdef struct DepDefaultsComp <: Component
            a::Int = 10
            b::Int = 2 * a
            c::Int = a + b
        end

        # default_parameters should evaluate without error and propagate values
        dp = default_parameters(DepDefaultsComp)
        @test dp.a == 10
        @test dp.b == 20       # 2 * 10
        @test dp.c == 30       # 10 + 20

        # Constructor should still work (it always did via kwarg scoping)
        comp = DepDefaultsComp()
        @test comp.a == 10
        @test comp.b == 20
        @test comp.c == 30

        # Parametric path: defaults that reference earlier parameters
        @compdef struct DepDefaultsParam{T} <: AbstractComponent{T}
            x::Int = 3
            y::Int = x^2
        end

        dp2 = default_parameters(DepDefaultsParam{typeof(1.0nm)})
        @test dp2.x == 3
        @test dp2.y == 9       # 3^2
    end
end

@testitem "Schematic rule checking: Hook styles" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout: hook_styles_match, _cross_sections_match, route!
    cpw_1 = Paths.SimpleCPW(10μm, 10μm)
    cpw_2 = Paths.SimpleCPW(10μm, 20μm)
    trace_1 = Paths.SimpleTrace(10μm)
    trace_2 = Paths.SimpleTrace(20μm)
    nr = Paths.NoRender()
    snr_1 = Paths.SimpleNoRender(10μm)
    snr_2 = Paths.SimpleNoRender(20μm)
    @test _cross_sections_match(cpw_1, cpw_1)
    @test !_cross_sections_match(cpw_1, cpw_2)
    @test _cross_sections_match(trace_1, trace_1)
    @test !_cross_sections_match(trace_1, trace_2)
    @test !_cross_sections_match(trace_1, cpw_1)
    @test !_cross_sections_match(trace_1, nr)
    @test !_cross_sections_match(cpw_1, nr)
    @test _cross_sections_match(nr, nr)
    @test !_cross_sections_match(snr_1, snr_2)
    @test _cross_sections_match(snr_1, snr_1)
    # Same dimensions in different units or with rounding error match
    @test _cross_sections_match(cpw_1, Paths.SimpleCPW(0.01mm, 0.01mm))
    @test _cross_sections_match(cpw_1, Paths.SimpleCPW((10 + 1e-12)μm, 10μm))
    @test !_cross_sections_match(cpw_1, Paths.SimpleCPW(10.001μm, 10μm))
    @test _cross_sections_match(trace_1, Paths.SimpleTrace(10_000.0nm))
    @test _cross_sections_match(snr_1, Paths.SimpleNoRender(0.01mm))

    # In a schematic
    pa1 = Path(; name="start", metadata=SemanticMeta(:test))
    straight!(pa1, 0.1mm, trace_1)

    pa2 = Path(Point(1mm, 0mm); name="stop", metadata=SemanticMeta(:test))
    straight!(pa2, 0.1mm, trace_2)
    terminate!(pa2; rounding=1μm)

    g = SchematicGraph("good")
    n1 = add_node!(g, pa1)
    fuse!(g, n1 => :p1, pa1 => :p0)
    sch = plan(g; log_dir=nothing)
    @test (@test_logs hook_styles_match(sch))

    g = SchematicGraph("bad")
    n1 = add_node!(g, pa2)
    fuse!(g, n1 => :p1, pa2 => :p0) # Terminated style doesn't match
    sch = plan(g; log_dir=nothing)
    @test !(@test_logs (:error, r"Mismatched cross sections") hook_styles_match(sch))

    g = SchematicGraph("bad")
    n1 = add_node!(g, pa1)
    fuse!(g, n1 => :p1, pa2 => :p0)
    sch = plan(g; log_dir=nothing)
    @test !(@test_logs (:error, r"Mismatched cross sections") hook_styles_match(sch))

    # Works for routes
    g = SchematicGraph("good")
    n1 = add_node!(g, pa1)
    n2 = add_node!(g, pa2)
    route!(
        g,
        Paths.StraightAnd90(1mm),
        n1 => :p1,
        n2 => :p0,
        Paths.TaperTrace(trace_1.width, trace_2.width),
        SemanticMeta(:test)
    )
    sch = plan(g; log_dir=nothing)
    @test (@test_logs hook_styles_match(sch))

    g = SchematicGraph("bad")
    n1 = add_node!(g, pa1)
    n2 = add_node!(g, pa2)
    route!(
        g,
        Paths.StraightAnd90(1mm),
        n1 => :p1,
        n2 => :p0,
        Paths.Trace(0.15mm),
        SemanticMeta(:test)
    )
    # Violations are logged to the console and the log file, then `check!` fails
    sch = @test_logs (:error, r"Mismatched cross sections.*start => :p1") (
        :error,
        r"Mismatched cross sections.*stop => :p0"
    ) (:error, r"failed design rule `hook_styles_match`") begin
        sch_logged = plan(g; log_dir=mktempdir())
        @test_throws "failed design rule checks" check!(
            sch_logged;
            rules=[hook_styles_match]
        )
        sch_logged
    end
    @test !sch.checked[]
    @test contains(
        read(sch.logger.logname, String),
        "check | [Error] Mismatched cross sections where"
    )
    # A rule that throws is reported and the remaining rules still run
    @test_logs (:error, r"`throwing_rule` threw an error") (
        :error,
        r"Mismatched cross sections"
    ) (:error, r"failed design rule `hook_styles_match`") match_mode = :any begin
        throwing_rule(_) = error("rule error")
        @test_throws "failed design rule checks" check!(
            plan(g; log_dir=nothing);
            rules=[throwing_rule, hook_styles_match]
        )
    end
    # Rerunning `check!` reports only the current violations
    check!(sch; rules=[])
    @test sch.checked[]

    # PeriodicStyle
    pa_template = Path(; name="periodic_template", metadata=SemanticMeta(:test))
    straight!(pa_template, 0.8mm, trace_1)
    straight!(pa_template, 0.8mm, trace_2)
    periodic_sty = Paths.PeriodicStyle(pa_template)
    g = SchematicGraph("good")
    n1 = add_node!(g, pa1)
    n2 = add_node!(g, pa2)
    route!(
        g,
        Paths.StraightAnd90(1mm),
        n1 => :p1,
        n2 => :p0,
        periodic_sty,
        SemanticMeta(:test)
    )
    sch = plan(g; log_dir=nothing)
    @test (@test_logs hook_styles_match(sch)) # Takes into account route length

    pa_template = Path(; name="periodic_template")
    straight!(pa_template, 0.4mm, trace_1)
    straight!(pa_template, 0.4mm, trace_2)
    periodic_sty = Paths.PeriodicStyle(pa_template)
    g = SchematicGraph("bad")
    n1 = add_node!(g, pa1)
    n2 = add_node!(g, pa2)
    route!(
        g,
        Paths.StraightAnd90(1mm),
        n1 => :p1,
        n2 => :p0,
        periodic_sty,
        SemanticMeta(:test)
    )
    sch = plan(g; log_dir=nothing)
    @test !(@test_logs (:error, r"Mismatched cross sections") hook_styles_match(sch))

    # Metadata must match, and undefined metadata never matches
    for (meta1, meta2, msg) in [
        (SemanticMeta(:test), SemanticMeta(:test2), r"metadata do not match"),
        (SemanticMeta(:test), DeviceLayout.UNDEF_META, r"metadata is undefined"),
        (DeviceLayout.UNDEF_META, DeviceLayout.UNDEF_META, r"metadata is undefined")
    ]
        pa_m1 = Path(; name="m1", metadata=meta1)
        straight!(pa_m1, 0.1mm, trace_1)
        pa_m2 = Path(Point(1mm, 0mm); name="m2", metadata=meta2)
        straight!(pa_m2, 0.1mm, trace_1)
        g_meta = SchematicGraph("meta")
        n_meta = add_node!(g_meta, pa_m1)
        fuse!(g_meta, n_meta => :p1, pa_m2 => :p0)
        @test !(@test_logs (:error, msg) hook_styles_match(plan(g_meta; log_dir=nothing)))
    end
    # Undefined overlay metadata never matches, and the message shows overlay metadata
    for (ometa1, ometa2, msg) in [
        (
            DeviceLayout.UNDEF_META,
            DeviceLayout.UNDEF_META,
            r"overlay metadata is undefined"
        ),
        (
            SemanticMeta(:a),
            SemanticMeta(:b),
            r"overlay metadata SemanticMeta\(:a.*overlay metadata SemanticMeta\(:b"s
        )
    ]
        pa_o1 = Path(; name="o1", metadata=SemanticMeta(:test))
        straight!(pa_o1, 0.1mm, trace_1)
        overlay!(pa_o1, trace_2, ometa1)
        pa_o2 = Path(Point(1mm, 0mm); name="o2", metadata=SemanticMeta(:test))
        straight!(pa_o2, 0.1mm, trace_1)
        overlay!(pa_o2, trace_2, ometa2)
        g_meta = SchematicGraph("overlay_meta")
        n_meta = add_node!(g_meta, pa_o1)
        fuse!(g_meta, n_meta => :p1, pa_o2 => :p0)
        @test !(@test_logs (:error, msg) hook_styles_match(plan(g_meta; log_dir=nothing)))
    end
    # Hooks without styles are not checked
    pa_undef = Path(; name="undef")
    straight!(pa_undef, 0.1mm, trace_1)
    g = SchematicGraph("bare")
    n1 = add_node!(g, WeatherVane{typeof(1.0nm)}())
    fuse!(g, n1 => :east, pa_undef => :p0)
    sch = plan(g; log_dir=nothing)
    @test (@test_logs hook_styles_match(sch))

    # Overlay
    pa_overlay_1 = Path(; name="start", metadata=SemanticMeta(:test))
    straight!(pa_overlay_1, 0.1mm, trace_1)
    overlay!(pa_overlay_1, trace_2, SemanticMeta(:test))

    pa_overlay_2 = Path(Point(1mm, 0mm); name="stop", metadata=SemanticMeta(:test))
    straight!(pa_overlay_2, 0.1mm, trace_1)
    overlay!(pa_overlay_2, trace_2, SemanticMeta(:test2)) # Different metadata

    @test _cross_sections_match(pa_overlay_1[1].sty, pa_overlay_1[1].sty)
    @test !_cross_sections_match(pa_overlay_1[1].sty, pa_overlay_2[1].sty)
    @test _cross_sections_match(pa_overlay_2[1].sty, pa_overlay_2[1].sty)
    # Overlays in a different order match
    ov(overlays...) = Paths.OverlayStyle(
        trace_1,
        collect(Paths.Style, first.(overlays)),
        collect(last.(overlays))
    )
    o1, o2 = (trace_2, SemanticMeta(:a)), (cpw_1, SemanticMeta(:b))
    @test _cross_sections_match(ov(o1, o2), ov(o2, o1))
    @test !_cross_sections_match(ov(o1, o2), ov(o1, o1))
    # Strands in different units match
    @test _cross_sections_match(
        Paths.Strands(5μm, 2μm, 2μm, 3),
        Paths.Strands(5000nm, 2000nm, 2000nm, 3)
    )
    @test !_cross_sections_match(
        Paths.Strands(5μm, 2μm, 2μm, 3),
        Paths.Strands(5μm, 2μm, 2μm, 2)
    )
    # Varying strands give their dimensions at the hook
    strands = @test_deprecated Paths.Strands(x -> 5μm, x -> 2μm + x / 10, x -> 2μm, 3)
    pa_strands = Path()
    @test_logs min_level = Logging.Error straight!(pa_strands, 100μm, strands)
    @test _cross_sections_match(
        hook_style(p0_hook(pa_strands)),
        Paths.Strands(5μm, 2μm, 2μm, 3)
    )
    @test _cross_sections_match(
        hook_style(p1_hook(pa_strands)),
        Paths.Strands(5μm, 12μm, 2μm, 3)
    )

    # Hand-written hook styles that are not cross sections
    function fused_hooks_sch(sty1, sty2)
        c1 = GDSComponent(
            Cell("h1", nm),
            (; p=StyledHook(PointHook(0μm, 0μm, 180°), sty1, SemanticMeta(:test)))
        )
        c2 = GDSComponent(
            Cell("h2", nm),
            (; p=StyledHook(PointHook(0μm, 0μm, 0°), sty2, SemanticMeta(:test)))
        )
        g = SchematicGraph("handwritten")
        n1 = add_node!(g, c1)
        fuse!(g, n1 => :p, c2 => :p)
        return plan(g; log_dir=nothing)
    end
    @test (@test_logs hook_styles_match(fused_hooks_sch(nr, nr)))
    taper = Paths.TaperTrace(10μm, 20μm)
    @test (@test_logs hook_styles_match(fused_hooks_sch(taper, taper)))

    # Building routes for the check doesn't hide routing errors from `build!`
    function bad_route_graph()
        pa_a = Path(; name="a", metadata=SemanticMeta(:test))
        straight!(pa_a, 0.1mm, trace_1)
        pa_b = Path(Point(1mm, 0.3mm); α0=45°, name="b", metadata=SemanticMeta(:test))
        straight!(pa_b, 0.1mm, trace_1)
        g = SchematicGraph("bad_route")
        n1 = add_node!(g, pa_a)
        n2 = add_node!(g, pa_b)
        rn = route!(
            g,
            Paths.StraightAnd90(0.05mm),
            n1 => :p1,
            n2 => :p0,
            trace_1,
            SemanticMeta(:test)
        )
        return g, rn
    end
    @test_logs (:error, r"same 4-point compass") match_mode = :any begin
        g, rn = bad_route_graph()
        sch = plan(g; log_dir=nothing)
        hooks(sch, rn)
        check!(sch)
        @test_throws "Encountered errors" build!(sch)

        g, rn = bad_route_graph()
        sch = plan(g; log_dir=nothing)
        @test_throws "failed design rule checks" check!(sch; rules=[hook_styles_match])
        @test isempty(component(rn)._path)
        check!(sch)
        @test_throws "Encountered errors" build!(sch)
    end

    # Checking doesn't keep route paths, so planning again routes to the new endpoints
    pa_end = Path(Point(1mm, 0mm); name="end", metadata=SemanticMeta(:test))
    straight!(pa_end, 0.1mm, trace_1)
    g = SchematicGraph("replan")
    n1 = add_node!(g, pa1)
    n2 = add_node!(g, pa_end)
    rn = route!(
        g,
        Paths.StraightAnd90(0.05mm),
        n1 => :p1,
        n2 => :p0,
        trace_1,
        SemanticMeta(:test)
    )
    sch = plan(g; log_dir=nothing)
    hooks(sch, rn)
    check!(sch; rules=[hook_styles_match])
    pa_end.p0 = Point(2mm, 0mm)
    sch = plan(g; log_dir=nothing)
    @test p1(SchematicDrivenLayout.path(component(rn))) ≈ Point(2mm, 0mm)

    # A failing check leaves a previously checked schematic unchecked
    sch = @test_logs (:error, r"failed design rule") begin
        sch_checked = plan(g; log_dir=nothing)
        check!(sch_checked; rules=[])
        @test sch_checked.checked[]
        @test_throws "failed design rule checks" check!(sch_checked; rules=[_ -> false])
        sch_checked
    end
    @test !sch.checked[]

    # Failures are detected even when the logger drops the error messages
    using Logging: NullLogger, with_logger
    for rule in (_ -> false, _ -> error("rule error"))
        with_logger(NullLogger()) do
            sch_null = plan(g; log_dir=nothing)
            @test_throws "failed design rule checks" check!(sch_null; rules=[rule])
            @test !sch_null.checked[]
        end
    end

    # Graph-level termination, including a rounded one that leaves only the termination style
    for kwargs in ((;), (; gap=0μm), (; rounding=2μm))
        pa_t = Path(; name="t", metadata=SemanticMeta(:test))
        straight!(pa_t, 0.1mm, cpw_1)
        g_t = SchematicGraph("terminated")
        n_t = add_node!(g_t, pa_t)
        terminate!(g_t, n_t => :p0; kwargs...)
        terminate!(g_t, n_t => :p1; kwargs...)
        @test (@test_logs hook_styles_match(plan(g_t; log_dir=nothing)))
    end

    # Building routes for the check leaves the planned route unchanged, so an S-shaped route,
    # where routing inserts a waypoint, plans and builds the same afterward
    function s_route_graph()
        pa_a = Path(; name="a", metadata=SemanticMeta(:test))
        straight!(pa_a, 0.1mm, trace_1)
        pa_b = Path(Point(1mm, 0.5mm); name="b", metadata=SemanticMeta(:test))
        straight!(pa_b, 0.1mm, trace_1)
        g = SchematicGraph("s_route")
        n1 = add_node!(g, pa_a)
        n2 = add_node!(g, pa_b)
        rn = route!(
            g,
            Paths.StraightAnd90(0.05mm),
            n1 => :p1,
            n2 => :p0,
            trace_1,
            SemanticMeta(:test)
        )
        return g, rn
    end
    route_points(rn) = [(p0(n.seg), p1(n.seg)) for n in component(rn)._path]
    built = map((true, false)) do with_rule
        g_s, rn_s = s_route_graph()
        sch_s = plan(g_s; log_dir=nothing)
        with_rule && check!(sch_s; rules=[hook_styles_match])
        @test isempty(component(rn_s).r.waypoints)
        sch_s = plan(g_s; log_dir=nothing)
        check!(sch_s)
        build!(sch_s)
        return route_points(rn_s)
    end
    @test built[1] == built[2]

    # A route that throws while it is built is reported, and the other hooks are still checked
    struct NoLegRule <: Paths.RouteRule end
    pa_a = Path(; name="a", metadata=SemanticMeta(:test))
    straight!(pa_a, 0.1mm, trace_1)
    pa_b = Path(Point(1mm, 0mm); name="b", metadata=SemanticMeta(:test))
    straight!(pa_b, 0.1mm, trace_1)
    pa_c = Path(; name="c", metadata=SemanticMeta(:test))
    straight!(pa_c, 0.1mm, trace_2)
    g_noleg = SchematicGraph("noleg")
    n_a = add_node!(g_noleg, pa_a)
    n_b = add_node!(g_noleg, pa_b)
    rn = route!(g_noleg, NoLegRule(), n_a => :p1, n_b => :p0, trace_1, SemanticMeta(:test))
    fuse!(g_noleg, n_b => :p1, pa_c => :p0)
    sch_noleg = plan(g_noleg; log_dir=nothing)
    @test !(@test_logs (:error, r"threw an error while it was built") (
        :error,
        r"Mismatched cross sections where b => :p1 is fused to c => :p0"
    ) hook_styles_match(sch_noleg))
    @test isempty(component(rn)._path)
end

@testitem "Schematic rule checking: Hook styles in composite components" setup =
    [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout: hook_styles_match, route!

    @compdef struct HookStylesComposite <: CompositeComponent
        name = "hsc"
        inner_width = 10μm
    end
    function SchematicDrivenLayout._build_subcomponents(cc::HookStylesComposite)
        pa = Path(; name="a", metadata=SemanticMeta(:test))
        straight!(pa, 0.1mm, Paths.Trace(10μm))
        pb = Path(Point(1mm, 0mm); name="b", metadata=SemanticMeta(:test))
        straight!(pb, 0.1mm, Paths.Trace(10μm))
        pc = Path(; name="c", metadata=SemanticMeta(:test))
        straight!(pc, 0.1mm, Paths.Trace(cc.inner_width))
        return (pa, pb, pc)
    end
    function SchematicDrivenLayout._graph!(
        g::SchematicGraph,
        ::HookStylesComposite,
        subcomps
    )
        na = add_node!(g, subcomps[1])
        nb = add_node!(g, subcomps[2])
        route!(
            g,
            Paths.StraightAnd90(0.05mm),
            na => :p1,
            nb => :p0,
            Paths.Trace(10μm),
            SemanticMeta(:test)
        )
        fuse!(g, nb => :p1, subcomps[3] => :p0)
        return g
    end

    # The hook name after the route doesn't need the route's hooks, which would warn
    cc = HookStylesComposite()
    @test (@test_logs SchematicDrivenLayout.decompose_hookname(cc, :_4_p1)) == (4 => :p1)
    pa_out = Path(; name="out", metadata=SemanticMeta(:test))
    straight!(pa_out, 0.1mm, Paths.Trace(10μm))
    g = SchematicGraph("outer")
    n = add_node!(g, cc)
    fuse!(g, n => :_4_p1, pa_out => :p0)
    @test (@test_logs hook_styles_match(plan(g; log_dir=nothing)))

    g = SchematicGraph("outer_bad")
    add_node!(g, HookStylesComposite(; name="bad", inner_width=20μm))
    @test !(@test_logs (:error, r"Mismatched cross sections in composite bad where") hook_styles_match(
        plan(g; log_dir=nothing)
    ))

    # Hooks that a composite exposes at a route's ends don't carry the route's attachments
    @compdef struct AttachedRouteComposite <: CompositeComponent
        name = "arc"
    end
    function SchematicDrivenLayout._build_subcomponents(::AttachedRouteComposite)
        pa = Path(; name="a", metadata=SemanticMeta(:test))
        straight!(pa, 0.1mm, Paths.Trace(10μm))
        pb = Path(Point(1mm, 0mm); name="b", metadata=SemanticMeta(:test))
        straight!(pb, 0.1mm, Paths.Trace(10μm))
        return (pa, pb)
    end
    function SchematicDrivenLayout._graph!(
        g::SchematicGraph,
        ::AttachedRouteComposite,
        subcomps
    )
        na = add_node!(g, subcomps[1])
        nb = add_node!(g, subcomps[2])
        rn = route!(
            g,
            Paths.StraightAnd90(0.05mm),
            na => :p1,
            nb => :p0,
            Paths.Trace(10μm),
            SemanticMeta(:test)
        )
        attach!(component(rn), sref(Cell("dot", nm)), 0.1mm)
        return g
    end
    pa_out = Path(; name="out", metadata=SemanticMeta(:test))
    straight!(pa_out, 0.1mm, Paths.Trace(10μm))
    g = SchematicGraph("outer_attached")
    n = add_node!(g, AttachedRouteComposite())
    fuse!(g, n => :_3_p1, pa_out => :p0)
    @test (@test_logs hook_styles_match(plan(g; log_dir=nothing)))
end

@testitem "Variant map_meta applies to hook metadata" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout.ExamplePDK.Transmons:
        ExampleXYTermination, ExampleStarTransmon
    import .SchematicDrivenLayout.ExamplePDK.LayerVocabulary: METAL_NEGATIVE

    @variant FlippedXYTermination ExampleXYTermination map_meta = facing
    @test hook_metadata(hooks(ExampleXYTermination()).line) == METAL_NEGATIVE
    @test hook_metadata(hooks(FlippedXYTermination()).line) == facing(METAL_NEGATIVE)
    # Graph-level termination uses the mapped metadata
    g = SchematicGraph("flipped")
    n = add_node!(g, FlippedXYTermination())
    @test component(terminate!(g, n => :line)).metadata == facing(METAL_NEGATIVE)

    @composite_variant FlippedStarTransmon ExampleStarTransmon map_meta = facing
    @test hook_metadata(hooks(ExampleStarTransmon()).z) == METAL_NEGATIVE
    @test hook_metadata(hooks(FlippedStarTransmon()).z) == facing(METAL_NEGATIVE)
    # Keyword values are resolved where the macro is called
    flip_here(m) = facing(m)
    star_name = "flipped_here"
    @composite_variant FlippedHereStarTransmon ExampleStarTransmon new_defaults =
        (; name=star_name) map_meta = flip_here
    @test FlippedHereStarTransmon().name == star_name
    @test hook_metadata(hooks(FlippedHereStarTransmon()).z) == facing(METAL_NEGATIVE)

    # Overlay metadata is mapped too
    pa = Path(; metadata=METAL_NEGATIVE)
    straight!(pa, 10μm, Paths.SimpleTrace(10μm))
    overlay!(pa, Paths.SimpleTrace(20μm), SemanticMeta(:test))
    mapped = SchematicDrivenLayout.map_hook_metadata((; p1=p1_hook(pa)), facing).p1
    @test hook_style(mapped).overlay_metadata == [facing(SemanticMeta(:test))]
    @test hook_metadata(mapped) == facing(METAL_NEGATIVE)
    # Geometry maps it too when the overlay has attachments
    attach!(pa, sref(Cell("attachment", nm)), 5μm)
    map_metadata!(pa, facing)
    @test Paths.without_attachments(pa[1].sty).overlay_metadata ==
          [facing(SemanticMeta(:test))]

    # Undefined metadata is mapped like any other, and array- and tuple-valued hooks are mapped
    # elementwise
    @compdef struct HookShapes <: Component
        name = "hs"
    end
    SchematicDrivenLayout._geometry!(cs::CoordinateSystem, ::HookShapes) =
        place!(cs, centered(Rectangle(10μm, 10μm)), METAL_NEGATIVE)
    SchematicDrivenLayout.hooks(::HookShapes) = (;
        undef=StyledHook(PointHook(0μm, 0μm, 0°), Paths.CPW(10μm, 6μm)),
        line=StyledHook(PointHook(0μm, 0μm, 0°), Paths.CPW(10μm, 6μm), METAL_NEGATIVE),
        grid=[PointHook(Point(i * 1μm, j * 1μm), 0°) for i = 1:2, j = 1:2],
        pair=(PointHook(0μm, 0μm, 0°), PointHook(1μm, 0μm, 0°))
    )
    layer_map = Dict(
        METAL_NEGATIVE => facing(METAL_NEGATIVE),
        DeviceLayout.UNDEF_META => SemanticMeta(:unset)
    )
    @variant HookShapesMapped HookShapes map_meta = m -> layer_map[m]
    hs = hooks(HookShapesMapped())
    @test hook_metadata(hs.undef) == SemanticMeta(:unset)
    @test hook_metadata(hs.line) == facing(METAL_NEGATIVE)
    @test hooks(HookShapesMapped(), :grid_3) == hooks(HookShapes(), :grid_3)
    @test hs.pair == hooks(HookShapes()).pair

    # Composite variant hooks are mapped once, whether or not the geometry was built first
    @compdef struct OverlayPathComposite <: CompositeComponent
        name = "opc"
    end
    function SchematicDrivenLayout._build_subcomponents(::OverlayPathComposite)
        pa = Path(; name="p", metadata=METAL_NEGATIVE)
        straight!(pa, 10μm, Paths.Trace(2μm))
        overlay!(pa, Paths.Trace(4μm), SemanticMeta(:test))
        return (pa,)
    end
    function SchematicDrivenLayout._graph!(
        g::SchematicGraph,
        ::OverlayPathComposite,
        subcomps
    )
        add_node!(g, subcomps[1])
        return g
    end
    @composite_variant FlippedOverlayPathComposite OverlayPathComposite map_meta = facing
    function p1_metadata(cc)
        h = hooks(cc)._1_p1
        return (hook_metadata(h), hook_style(h).overlay_metadata)
    end
    expected = (facing(METAL_NEGATIVE), [facing(SemanticMeta(:test))])
    hooks_first = FlippedOverlayPathComposite()
    @test p1_metadata(hooks_first) == expected
    geometry(hooks_first)
    @test p1_metadata(hooks_first) == expected
    geometry_first = FlippedOverlayPathComposite()
    geometry(geometry_first)
    @test p1_metadata(geometry_first) == expected

    # An overlay style shared by a parameter, a hook, and several segments is mapped once for
    # each, and the parameter is unchanged
    overlay_map = Dict(
        SemanticMeta(:a) => SemanticMeta(:b),
        SemanticMeta(:b) => SemanticMeta(:c),
        METAL_NEGATIVE => METAL_NEGATIVE
    )
    @compdef struct SharedOverlay <: Component
        name = "so"
        sty = Paths.OverlayStyle(
            Paths.Trace(10μm),
            Paths.Style[Paths.Trace(2μm)],
            DeviceLayout.Meta[SemanticMeta(:a)]
        )
    end
    function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, c::SharedOverlay)
        pa = Path(; metadata=METAL_NEGATIVE)
        straight!(pa, 10μm, c.sty)
        straight!(pa, 10μm, c.sty)
        return addref!(cs, pa)
    end
    SchematicDrivenLayout.hooks(c::SharedOverlay) =
        (; p=StyledHook(PointHook(0μm, 0μm, 0°), c.sty, METAL_NEGATIVE))
    @variant SharedOverlayMapped SharedOverlay map_meta = m -> overlay_map[m]
    v = SharedOverlayMapped()
    @test hook_style(hooks(v).p).overlay_metadata == [SemanticMeta(:b)]
    pa_v = structure(only(refs(geometry(v))))
    @test all(n -> n.sty.overlay_metadata == [SemanticMeta(:b)], pa_v.nodes)
    @test hook_style(hooks(v).p).overlay_metadata == [SemanticMeta(:b)]
    @test v.sty.overlay_metadata == [SemanticMeta(:a)]
end
