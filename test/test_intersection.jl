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
end

@testitem "Crossover clears decorations (#15)" setup = [CommonTestSetup] begin
    # Create a horizontal path (pa1) with decorations — this path will be CROSSED
    pa1 = Path(0μm, 0μm)
    straight!(pa1, 200μm, Paths.Trace(10μm))

    # Add decorations at known positions along pa1
    dummy_deco = Cell("deco", nm)
    for t in [20μm, 40μm, 60μm, 80μm, 100μm, 120μm, 160μm, 180μm]
        attach!(pa1, sref(dummy_deco), t)
    end
    n_before = length(pa1[1].sty.ts)
    @test n_before == 8

    # Create a vertical path (pa2) that crosses pa1 at x ≈ 100μm
    # pa2 crosses over pa1 (pa2 is listed AFTER pa1 in intersect!)
    pa2 = Path(100μm, -100μm, α0=π / 2)
    straight!(pa2, 200μm, Paths.Trace(10μm))

    xsty = Intersect.AirBridge(
        crossing_gap=5μm,
        foot_gap=2μm,
        foot_length=4μm,
        extent_gap=2μm,
        scaffold_gap=5μm,
        scaffold_meta=GDSMeta(1),
        air_bridge_meta=GDSMeta(2)
    )
    Intersect.intersect!(xsty, pa1, pa2)

    # Count remaining decorations on pa1 — some near the crossing should be removed
    # pa1 is the crossed path (not spliced), so it still has one segment
    n_after = length(pa1[1].sty.ts)
    @test n_after < n_before  # Some decorations near the crossing were cleared

    # Decorations far from the crossing (e.g. at 20μm, 180μm) should survive
    @test n_after > 0

    # Verify the result renders without error
    c = Cell("deco_crossing", nm)
    render!(c, pa1, GDSMeta(0))
    render!(c, pa2, GDSMeta(0))
end
