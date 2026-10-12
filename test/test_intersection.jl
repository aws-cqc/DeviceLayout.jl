@testitem "Path intersections" setup = [CommonTestSetup] begin
    paths_vert = [Path(i * 0.1mm, (-1)^(i + 1) * (1mm), α0=(-1)^i * π / 2) for i = -5:5]
    paths_horiz =
        [Path((-1)^(i) * (1mm), i * 0.1mm, α0=(-1)^i * π / 2 + π / 2) for i = -5:5]

    sty = Paths.SimpleCPW(10μm, 6μm)
    straight!.(paths_vert, 2mm, Ref(sty))
    straight!.(paths_horiz, 2mm, Ref(sty))

    xsty = Intersect.AirBridge(
        crossing_gap=5μm,
        foot_gap=2μm,
        foot_length=4μm,
        extent_gap=2μm,
        scaffold_gap=5μm,
        scaffold_meta=GDSMeta(1),
        air_bridge_meta=GDSMeta(2)
    )
    Intersect.intersect!(
        xsty,
        paths_vert[1:2:end]...,
        paths_horiz[2:2:end]...,
        paths_vert[2:2:end]...,
        paths_horiz[1:2:end]...
    )

    x_dummy = Intersect.intersection(xsty, paths_vert[1][1], 100μm, 1mm)
    added_nodes_per_crossing = length(x_dummy) + 1

    @test length.(paths_horiz) ==
          added_nodes_per_crossing * [11, 6, 11, 6, 11, 6, 11, 6, 11, 6, 11] .+ 1
    @test length.(paths_vert) ==
          added_nodes_per_crossing * [0, 5, 0, 5, 0, 5, 0, 5, 0, 5, 0] .+ 1

    c = Cell("int", nm)
    render!.(c, paths_vert, GDSMeta(0))
    render!.(c, paths_horiz, GDSMeta(0))

    ### Terminations around a crossing share vertices with the adjacent CPW gaps
    # The termination after the bridge faces the following segment, so its trace-corner
    # vertices must sit on that side; otherwise the following gap strips meet its edge in
    # T-junctions.
    pv = Path(Point(0.0μm, -500.0μm); α0=90°)
    ph = Path(Point(-500.0μm, 0.0μm))
    straight!.((pv, ph), 1mm, Ref(sty))
    Intersect.intersect!(xsty, pv, ph)
    c = Cell("int", nm)
    render!(c, ph, GDSMeta(0))
    gaps = [p for (p, m) in zip(c.elements, c.element_metadata) if m == GDSMeta(0)]
    @test split_t_junctions!(copy.(gaps), gaps) == 0

    ### Crossings with a long meandering path
    paths_vert = [Path(i * 0.1mm, (-1)^(i + 1) * (1mm), α0=(-1)^i * π / 2) for i = -5:5]
    straight!.(paths_vert, 2mm, Ref(sty))
    path_horiz = Path(-1mm, 0.5mm)
    for i = 1:11
        straight!(path_horiz, 2mm, sty)
        turn!(path_horiz, (-1)^i * π, 0.05mm)
    end

    Intersect.intersect!(xsty, paths_vert[1:2:end]..., path_horiz, paths_vert[2:2:end]...)
    c = Cell("int", nm)
    render!.(c, paths_vert, GDSMeta(0))
    render!(c, path_horiz, GDSMeta(0))
    @test length(path_horiz) == 6 * 11 * added_nodes_per_crossing + 2 * 11

    ### Crossing a decorated spline (runs without error)
    dummy_bridge = Cell("empty", nm)
    paths_vert = [Path(i * 0.1mm, (-1)^(i + 1) * (1mm), α0=(-1)^i * π / 2) for i = -5:5]
    straight!.(paths_vert, 2mm, Ref(sty))
    path_horiz = Path(-1mm, 0.5mm)
    bspline!(
        path_horiz,
        Point.([
            (-0.4mm, 0.4mm),
            (-0.0mm, 0.3mm),
            (0.25mm, 0.0mm),
            (0.5mm, -0.8mm),
            (1mm, -0.5mm)
        ]),
        0,
        sty
    )
    attach!(path_horiz, sref(dummy_bridge), 0.1mm)
    Intersect.intersect!(xsty, path_horiz, paths_vert...)
    c = Cell("int", nm)
    render!.(c, paths_vert, GDSMeta(0))
    render!(c, path_horiz, GDSMeta(0))

    turn = Paths.Turn(π / 4, 1.0) # turn starting at zero, pointing right
    @test pathlength_nearest(turn, Point(-1, 0)) == 0
    @test pathlength_nearest(turn, Point(2, 0)) ≈ π / 4
    turn = Paths.Turn(-270.0°, 1.0, Point(0, -1.0), 180.0°)
    @test pathlength_nearest(turn, Point(1, -0.9)) ≈ 3π / 2
    @test pathlength_nearest(turn, Point(0.9, -2)) ≈ 0
    @test pathlength_nearest(turn, Point(-1, 1)) ≈ 3π / 4

    @testset "sweep for intersections" begin
        # Crossing straights, a meander with curved segments, and a self-crossing loop
        pas = [Path(i * 0.1mm, -1mm, α0=π / 2 + 0.1i) for i = -5:5]
        straight!.(pas, 2mm, Ref(sty))
        meander = Path(-1mm, 0.5mm)
        for i = 1:5
            straight!(meander, 2mm, sty)
            turn!(meander, (-1)^i * π, 0.05mm)
        end
        loop = Path(-0.3mm, -0.3mm)
        straight!(loop, 0.5mm, sty)
        turn!(loop, 3π / 2, 0.1mm)
        straight!(loop, 0.5mm)
        all_paths = (pas..., meander, loop)
        from_sweep = Intersect.intersections(all_paths...)
        @test all(i1 < i2 for (i1, i2, _) in from_sweep)
        # Reference: test every pair of segments with the same endpoint-intersection predicate
        all_segs = Tuple{Int, Int, Polygons.LineSegment}[]
        for (pa_idx, pa) in enumerate(all_paths)
            inds, segs = Paths.line_segments(pa)
            append!(all_segs, ((pa_idx, n, s) for (n, s) in zip(inds, segs)))
        end
        reference = Set{Tuple{Tuple{Int, Int}, Tuple{Int, Int}}}()
        for (a, (i1, n1, s1)) in enumerate(all_segs)
            for (i2, n2, s2) in all_segs[(a + 1):end]
                intersects, atapoint, atendpoints = Polygons.intersects_at_endpoint(s1, s2)
                if intersects && atapoint && !atendpoints
                    push!(reference, minmax((i1, n1), (i2, n2)))
                end
            end
        end
        @test length(from_sweep) == length(reference)
        @test Set(minmax(i1, i2) for (i1, i2, _) in from_sweep) == reference
        @test any(i1[1] == i2[1] for (i1, i2, _) in from_sweep) # loop self-intersection
    end

    @testset "mixed coordinate contexts (issue #212)" begin
        pa1 = Path(μm)  # μm-context
        Paths.turn!(pa1, -360°, 100μm, Paths.CPW(10μm, 6μm))
        pa2 = Path(Point(0, 100)μm, α0=-90°)  # nm-context (preferred)
        Paths.straight!(pa2, 400μm, Paths.CPW(10μm, 6μm))
        Paths.turn!(pa2, 270°, 200μm)
        Paths.straight!(pa2, 400μm)
        # Should not throw MethodError on mixed coordinate contexts
        @test Intersect.intersections(pa1, pa2) isa Vector
    end
end
