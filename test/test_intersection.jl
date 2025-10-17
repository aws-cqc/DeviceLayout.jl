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
