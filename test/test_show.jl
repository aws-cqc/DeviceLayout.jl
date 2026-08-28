@testitem "Pretty printing" setup = [CommonTestSetup] begin
    using .SchematicDrivenLayout
    import .SchematicDrivenLayout: SchematicGraph, ComponentNode, add_node!, plan, nodes

    showstr(x) = sprint(show, MIME"text/plain"(), x)
    compactstr(x) = sprint(show, x)

    # Path
    pa = Path(nm; name="showpath", metadata=SemanticMeta(:metal))
    straight!(pa, 100μm, Paths.Trace(2μm))
    turn!(pa, 90°, 50μm)
    spa = showstr(pa)
    @test contains(spa, "Path \"showpath\"")
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
    @test compactstr(pa) == "Path \"showpath\" with 2 nodes"

    # Empty path doesn't error and has no endpoint/node lines
    pe = Path(nm; name="emptypath")
    se = showstr(pe)
    @test contains(se, "Path \"emptypath\"")
    @test contains(se, "0 nodes")
    @test contains(se, "from (0.0 nm,0.0 nm)")
    @test !contains(se, "\n  to ")
    @test compactstr(pe) == "Path \"emptypath\" with 0 nodes"

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

    # SchematicGraph, ComponentNode, Schematic
    g = SchematicGraph("showgraph")
    n1 = add_node!(g, pa)
    sg = showstr(g)
    @test contains(sg, "SchematicGraph \"showgraph\"")
    @test contains(sg, "1 node")
    @test contains(sg, "0 edges")
    @test contains(sg, "[1] \"showpath\" (Path)")
    @test compactstr(g) == "SchematicGraph \"showgraph\" with 1 node and 0 edges"

    @test compactstr(n1) == "ComponentNode \"showpath\" (Path)"

    sch = plan(g; log_dir=nothing)
    ss = showstr(sch)
    @test contains(ss, "Schematic \"showgraph\"")
    @test contains(ss, "1 node")
    @test contains(ss, "0 edges")
    @test contains(ss, "coordinate system:")
    @test contains(ss, "checked: false")
    @test contains(ss, "[1] \"showpath\" (Path)")
    @test contains(compactstr(sch), "Schematic \"showgraph\" with 1 node and 0 edges")
end

@testitem "Pretty printing (SolidModel)" setup = [CommonTestSetup] begin
    import DeviceLayout.SolidModels

    sm0 = SolidModel("showmodel_empty"; overwrite=true)
    s0 = sprint(show, MIME"text/plain"(), sm0)
    @test contains(s0, "SolidModel \"showmodel_empty\"")
    @test contains(s0, "OpenCascade kernel")
    @test contains(s0, "0 physical groups")

    cs = CoordinateSystem("showmodel_cs", nm)
    place!(cs, Rectangle(10μm, 10μm), :test_layer)
    sm = SolidModel("showmodel"; overwrite=true)
    render!(sm, cs)
    ssm = sprint(show, MIME"text/plain"(), sm)
    @test contains(ssm, "SolidModel \"showmodel\"")
    @test contains(ssm, "physical group")
    @test contains(ssm, "dim 2: ")
    @test contains(ssm, "test_layer")
    @test contains(sprint(show, sm), "SolidModel \"showmodel\"")
end
