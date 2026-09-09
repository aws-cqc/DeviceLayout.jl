@testitem "Pretty printing" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import Graphs
    import .SchematicDrivenLayout:
        AbstractComponent, SchematicGraph, ComponentNode, add_node!, plan, nodes

    showstr(x) = sprint(show, MIME"text/plain"(), x)
    compactstr(x) = sprint(show, x)

    # CommonTestSetup imports plain Unitful units as `nm` etc., so use its `nm2nm` alias
    # for `PreferNanometers.nm` where the short coordinate type string is expected

    # Path
    pa = Path(nm2nm; name="showpath", metadata=SemanticMeta(:metal))
    straight!(pa, 100μm, Paths.Trace(2μm))
    turn!(pa, 90°, 50μm)
    spa = showstr(pa)
    @test contains(spa, "Path{typeof(1.0nm)} \"showpath\"")
    @test contains(spa, "2 nodes")
    @test contains(spa, "and metadata ")
    @test contains(spa, "SemanticMeta(:metal")
    @test contains(spa, "from (0.0 nm,0.0 nm)")
    @test contains(spa, "∠0.0°")
    @test contains(spa, "to (150000.0 nm,50000.0 nm)")
    @test contains(spa, "∠90.0°")
    @test contains(spa, "[1] Straight")
    @test contains(spa, "[2] Turn")
    # Compact (2-arg) form is a single line
    @test compactstr(pa) == "Path{typeof(1.0nm)} \"showpath\" with 2 nodes"

    # Empty path doesn't error and has no endpoint/node lines
    pe = Path(nm2nm; name="emptypath")
    se = showstr(pe)
    @test contains(se, "Path{typeof(1.0nm)} \"emptypath\"")
    @test contains(se, "0 nodes")
    @test contains(se, "from (0.0 nm,0.0 nm)")
    @test !contains(se, "\n  to ")
    @test compactstr(pe) == "Path{typeof(1.0nm)} \"emptypath\" with 0 nodes"
    escaped_name = "path\"name\nnext"
    @test compactstr(Path(nm2nm; name=escaped_name)) ==
          "Path{typeof(1.0nm)} $(repr(escaped_name)) with 0 nodes"

    # Coordinate type strings: short names for common types, module-qualified when the
    # promotion context differs from the package preference, full type otherwise
    import DeviceLayout: coordinate_type_string, PreferMicrons, PreferNanometers
    @test coordinate_type_string(typeof(1.0nm2nm)) == "typeof(1.0nm)"
    @test coordinate_type_string(typeof(1μm2nm)) == "typeof(1μm)"
    @test coordinate_type_string(typeof(1.0PreferNanometers.μm)) == "typeof(1.0μm)"
    @test coordinate_type_string(typeof(1.0PreferMicrons.μm)) ==
          "typeof(1.0PreferMicrons.μm)"
    @test coordinate_type_string(typeof(1.0Unitful.μm)) == "typeof(1.0Unitful.μm)"
    @test coordinate_type_string(Float64) == "Float64"
    @test coordinate_type_string(typeof(1.0f0nm)) == string(typeof(1.0f0nm))
    @test compactstr(Cell("showcell", nm2nm)) ==
          "Cell{typeof(1.0nm)} \"showcell\" with 0 els, 0 refs"
    @test compactstr(CoordinateSystem("showcs", PreferMicrons.μm)) ==
          "CoordinateSystem{typeof(1.0PreferMicrons.μm)} \"showcs\" with 0 els, 0 refs"
    @test contains(showstr(Spacer{typeof(1.0nm2nm)}()), "Spacer{typeof(1.0nm)} \"spacer\"")
    # Types built from plain Unitful units are flagged as such
    @test compactstr(Cell("showcell", nm)) ==
          "Cell{typeof(1.0Unitful.nm)} \"showcell\" with 0 els, 0 refs"

    # Long paths are truncated when the IOContext is limited
    plong = Path(nm; name="longpath")
    for _ = 1:30
        straight!(plong, 10μm, Paths.Trace(2μm))
    end
    slim = sprint(show, MIME"text/plain"(), plong, context=:limit => true)
    @test contains(slim, "30 nodes")
    @test contains(slim, "⋮")
    @test contains(slim, "[30] Straight")
    @test !contains(slim, "[15] Straight")
    sfull = showstr(plong)
    @test contains(sfull, "[15] Straight")
    @test !contains(sfull, "⋮")

    # Route
    r = Route(
        Paths.StraightAnd90(min_bend_radius=50μm),
        Point(0.0μm, 0.0μm),
        Point(100.0μm, 100.0μm),
        0°,
        90°
    )
    sr = compactstr(r)
    @test contains(sr, "Route from (0.0 μm,0.0 μm) @ 0.0°")
    @test contains(sr, "to (100.0 μm,100.0 μm) @ 90.0°")
    @test contains(sr, "rule StraightAnd90")
    @test !contains(sr, "waypoint")
    r2 = Route(
        Paths.StraightAnd90(min_bend_radius=50μm),
        Point(0.0μm, 0.0μm),
        Point(100.0μm, 100.0μm),
        0°,
        90°;
        waypoints=[Point(50.0μm, 50.0μm)]
    )
    @test contains(compactstr(r2), "via 1 waypoint")
    sr2 = showstr(r2)
    @test contains(sr2, "rule: StraightAnd90(")
    @test contains(sr2, "min_bend_radius=50 μm")
    @test contains(sr2, "waypoints: [(50.0 μm,50.0 μm)]")
    @test contains(sr2, "waydirs: ")

    # Concrete component types retain every real parameter while abbreviating coordinates
    struct FixedCoordinateComponent <: AbstractComponent{Float64}
        name::String
    end
    fixed_display = showstr(FixedCoordinateComponent("fixed"))
    @test contains(fixed_display, "FixedCoordinateComponent \"fixed\"")
    @test !contains(fixed_display, "FixedCoordinateComponent{")
    rc = RouteComponent("showroute", r, false, Paths.Trace(2μm), SemanticMeta(:route))
    route_component_display = showstr(rc)
    @test contains(route_component_display, "RouteComponent{")
    @test contains(route_component_display, "StraightAnd90")
    @test contains(route_component_display, "\"showroute\"")

    # SchematicGraph, ComponentNode, Schematic
    g = SchematicGraph("showgraph")
    n1 = add_node!(g, pa)
    sg = showstr(g)
    @test contains(sg, "SchematicGraph \"showgraph\"")
    @test contains(sg, "1 node")
    @test contains(sg, "0 edges")
    @test contains(sg, "[1] \"showpath\" (Path{typeof(1.0nm)})")
    @test contains(sg, "edges: none")
    @test compactstr(g) == "SchematicGraph \"showgraph\" with 1 node and 0 edges"

    @test compactstr(n1) == "ComponentNode \"showpath\" (Path{typeof(1.0nm)})"

    sch = plan(g; log_dir=nothing)
    ss = showstr(sch)
    @test contains(ss, "Schematic{typeof(1.0nm)} \"showgraph\"")
    @test contains(ss, "1 node")
    @test contains(ss, "0 edges")
    @test contains(ss, "coordinate system:")
    @test contains(ss, "checked: false")
    @test contains(ss, "[1] \"showpath\" (Path{typeof(1.0nm)})")
    @test contains(
        compactstr(sch),
        "Schematic{typeof(1.0nm)} \"showgraph\" with 1 node and 0 edges"
    )

    p2 = Path(nm2nm; name="other")
    add_node!(g, p2)
    Graphs.add_edge!(g.graph, 1, 2)
    sg_connected = showstr(g)
    @test contains(sg_connected, "edges:\n   [1] \"showpath\" — \"other\"")
    escaped_graph_name = "graph\"name\nnext"
    @test startswith(
        compactstr(SchematicGraph(escaped_graph_name)),
        "SchematicGraph $(repr(escaped_graph_name))"
    )
end

@testitem "Pretty printing (SolidModel)" setup = [CommonTestSetup, QuietGmshSetup] begin
    import DeviceLayout.SolidModels

    sm0 = SolidModel("showmodel_empty"; overwrite=true)
    s0 = sprint(show, MIME"text/plain"(), sm0)
    @test contains(s0, "SolidModel \"showmodel_empty\"")
    @test contains(s0, "OpenCascade kernel")
    @test contains(s0, "0 physical groups")

    cs = CoordinateSystem("showmodel_cs", nm)
    place!(cs, Rectangle(10μm, 10μm), :test_layer)
    sm = SolidModel("showmodel"; overwrite=true)
    quiet_test_output(
        allowed_output=line ->
            strip(line) == "Boolean fragments skipped - too few arguments"
    ) do
        return render!(sm, cs)
    end
    SolidModel("showmodel_other"; overwrite=true)
    current_model = SolidModels.gmsh.model.get_current()
    ssm = sprint(show, MIME"text/plain"(), sm)
    @test SolidModels.gmsh.model.get_current() == current_model
    @test contains(ssm, "SolidModel \"showmodel\"")
    @test contains(ssm, "physical group")
    @test contains(ssm, "dim 2:")
    @test contains(ssm, "\"test_layer\": 1 entity")
    @test contains(sprint(show, sm), "SolidModel \"showmodel\"")

    escaped_name = "show\"model\nnext"
    escaped_model = SolidModel(escaped_name; overwrite=true)
    @test contains(sprint(show, escaped_model), "SolidModel $(repr(escaped_name))")
end

@testitem "Pretty printing (entities, styles, hooks, references)" setup = [CommonTestSetup] begin
    import DeviceLayout:
        Rounded,
        MeshSized,
        OptionalStyle,
        ToTolerance,
        Plain,
        StyleDict,
        CurvilinearPolygon,
        CurvilinearRegion
    import DeviceLayout.Texts: Text

    showstr(x) = sprint(show, MIME"text/plain"(), x)
    compactstr(x) = sprint(show, x)
    limitstr(x) = sprint(show, x; context=:limit => true)

    # Entities
    r = Rectangle(10μm, 5μm)
    @test compactstr(r) == "Rectangle((0 μm,0 μm), (10 μm,5 μm))"
    tri = Polygon([Point(0μm, 0μm), Point(1μm, 0μm), Point(0μm, 1μm)])
    @test compactstr(tri) == "Polygon((0 μm,0 μm), (1 μm,0 μm), (0 μm,1 μm))"
    @test limitstr(tri) == compactstr(tri) # small polygons are shown in full
    stri = showstr(tri)
    @test contains(stri, "Polygon with 3 points")
    @test contains(stri, "[1] (0 μm,0 μm)")
    @test contains(stri, "[3] (0 μm,1 μm)")
    big = Polygon([Point(i * 1.0μm, 0.0μm) for i = 1:50])
    @test limitstr(big) == "Polygon with 50 points"
    @test startswith(compactstr(big), "Polygon((1.0 μm,0.0 μm), ")
    sbig = sprint(show, MIME"text/plain"(), big; context=:limit => true)
    @test contains(sbig, "⋮")
    @test contains(sbig, "[50] (50.0 μm,0.0 μm)")
    @test !contains(sbig, "[25] ")
    @test contains(showstr(big), "[25] ")
    @test compactstr(Ellipse(Point(0μm, 0μm), (2μm, 1μm), 0°)) ==
          "Ellipse((0 μm,0 μm), (2 μm, 1 μm), 0.0°)"
    cp = difference2d(Rectangle(10μm, 10μm), Rectangle(2μm, 2μm))
    @test compactstr(cp) == "ClippedPolygon with 1 outer contour and 0 holes"
    cp2 = difference2d(Rectangle(10μm, 10μm), Rectangle(2μm, 2μm) + Point(4μm, 4μm))
    @test compactstr(cp2) == "ClippedPolygon with 1 outer contour and 1 hole"
    ctri = CurvilinearPolygon(points(tri))
    @test compactstr(ctri) == "CurvilinearPolygon with 3 points and 0 curves"
    sctri = showstr(ctri)
    @test contains(sctri, "points:\n   [1] (0 μm,0 μm)")
    @test contains(sctri, "curve start indices: Int64[]")
    @test contains(sctri, "curves: none")
    rounded_r = to_polygons(Rounded(1.0μm)(r)) # sanity check that rounding works
    circle_region = CurvilinearRegion(CurvilinearPolygon(Circle(1.0μm)))
    @test compactstr(circle_region) ==
          "CurvilinearRegion with 4-point exterior (4 curves) and 0 holes"
    scircle_region = showstr(circle_region)
    @test contains(scircle_region, "exterior:")
    @test contains(scircle_region, "curve start indices: [1, 2, 3, 4]")
    @test contains(scircle_region, "[1] Turn by 90.0°")
    @test contains(scircle_region, "holes: none")
    region_with_hole = CurvilinearRegion(
        CurvilinearPolygon(points(Rectangle(10.0μm, 10.0μm))),
        [
            CurvilinearPolygon(
                points(centered(Rectangle(2.0μm, 2.0μm); on_pt=Point(5.0μm, 5.0μm)))
            )
        ]
    )
    hole_display = showstr(region_with_hole)
    @test contains(hole_display, "holes:\n   [1] CurvilinearPolygon with 4 points")
    @test contains(hole_display, "[4] (4.0 μm,4.0 μm)")
    @test compactstr(Text("hi", Point(0μm, 0μm))) ==
          "Text \"hi\" at (0 μm,0 μm) with width 0 μm"
    @test compactstr(Text("hi", Point(0μm, 0μm); rot=90°)) ==
          "Text \"hi\" at (0 μm,0 μm) with width 0 μm with Rotation(90.0°)"
    detailed_text = showstr(
        Text(
            "hi",
            Point(0μm, 0μm);
            can_scale=true,
            xalign=Align.RightEdge(),
            yalign=Align.BottomEdge()
        )
    )
    @test contains(detailed_text, "can scale: true")
    @test contains(detailed_text, "x alignment: DeviceLayout.Align.RightEdge()")
    @test contains(detailed_text, "y alignment: DeviceLayout.Align.BottomEdge()")

    # Styles and styled entities
    @test compactstr(Rounded(1μm)) == "Rounded(1.0 μm)"
    @test compactstr(Rounded(1μm; min_side_len=3μm)) ==
          "Rounded(1.0 μm; min_side_len=3.0 μm)"
    @test compactstr(Rounded{typeof(1.0μm)}(; rel_r=0.2)) ==
          "Rounded{typeof(1.0Unitful.μm)}(; rel_r=0.2)"
    selected_rounding = Rounded(1μm; p0=[Point(0μm, 0μm)], selection_tolerance=1nm)
    @test compactstr(selected_rounding) ==
          "Rounded(1.0 μm; 1 selected point, selection_tolerance=0.001 μm)"
    selected_rounding_detail = showstr(selected_rounding)
    @test contains(selected_rounding_detail, "selected points:\n   [1] (0.0 μm,0.0 μm)")
    @test contains(selected_rounding_detail, "selection tolerance: 0.001 μm")
    @test compactstr(Rounded{typeof(1.0μm)}()) == "Rounded{typeof(1.0Unitful.μm)}()"
    @test contains(
        compactstr(Rounded{typeof(1.0μm)}(; selection_tolerance=-Inf * μm)),
        "selection_tolerance=-Inf μm"
    )
    @test contains(
        compactstr(Rounded{typeof(1.0μm)}(; selection_tolerance=NaN * μm)),
        "selection_tolerance=NaN μm"
    )
    @test compactstr(MeshSized(1μm)) == "MeshSized(1 μm)"
    @test compactstr(MeshSized(1μm, 0.5)) == "MeshSized(1 μm, α=0.5)"
    @test compactstr(OptionalStyle(Rounded(1μm), :rounding)) ==
          "OptionalStyle(Rounded(1.0 μm), :rounding)"
    @test compactstr(
        OptionalStyle(Rounded(1μm), :rounding; false_style=ToTolerance(1nm), default=false)
    ) ==
          "OptionalStyle(Rounded(1.0 μm), :rounding, false_style=ToTolerance(1 nm), default=false)"
    @test compactstr(ToTolerance(1nm)) == "ToTolerance(1 nm)"
    @test compactstr(StyleDict()) == "StyleDict with default Plain() and 0 overrides"
    style_dict = StyleDict()
    style_dict[1, 2] = Rounded(1μm)
    style_dict_display = showstr(style_dict)
    @test contains(style_dict_display, "overrides:\n   [1, 2] => Rounded(1.0 μm)")
    se = Rounded(1μm)(r)
    @test compactstr(se) == "Rectangle((0 μm,0 μm), (10 μm,5 μm)) styled as Rounded(1.0 μm)"
    sse = showstr(Rounded(1μm)(tri))
    @test contains(sse, "Polygon with 3 points")
    @test contains(sse, "[3] (0 μm,1 μm)")
    @test endswith(sse, "\n  style: Rounded(1.0 μm)")

    # Hooks
    ph = PointHook(Point(0μm, 1μm), 90°)
    @test compactstr(ph) == "PointHook((0 μm,1 μm), 90.0°)"
    @test compactstr(HandedPointHook(Point(0μm, 1μm), 90°)) ==
          "HandedPointHook((0 μm,1 μm), 90.0°)"
    @test compactstr(HandedPointHook(Point(0μm, 1μm), 90°, false)) ==
          "HandedPointHook((0 μm,1 μm), 90.0°, false)"
    @test compactstr(StyledHook(ph, Paths.Trace(2μm))) ==
          "PointHook((0 μm,1 μm), 90.0°) styled as Trace with width 2.0 μm"

    # References
    c = Cell("showrefcell", nm2nm)
    @test compactstr(sref(c, Point(1μm, 2μm))) ==
          "StructureReference at (1.0 μm,2.0 μm) to Cell{typeof(1.0nm)} \"showrefcell\" with 0 els, 0 refs"
    @test compactstr(sref(c, Point(1μm, 2μm); rot=90°, xrefl=true)) ==
          "StructureReference at (1.0 μm,2.0 μm) with Rotation(90.0°) ∘ XReflection() to Cell{typeof(1.0nm)} \"showrefcell\" with 0 els, 0 refs"
    @test compactstr(
        aref(c, Point(1μm, 2μm); dc=Point(10μm, 0μm), dr=Point(0μm, 10μm), nc=3, nr=4)
    ) ==
          "ArrayReference at (1.0 μm,2.0 μm) of 3 × 4 (cols × rows) spaced by (10.0 μm,0.0 μm), (0.0 μm,10.0 μm) to Cell{typeof(1.0nm)} \"showrefcell\" with 0 els, 0 refs"

    # BSpline
    b = Paths.BSpline(
        [Point(0μm, 0μm), Point(10μm, 10μm), Point(20μm, 0μm)],
        Point(1μm, 0μm),
        Point(1μm, 0μm)
    )
    @test compactstr(b) ==
          "BSpline through 3 points from (0.0 μm,0.0 μm) to (20.0 μm,0.0 μm)"
end
