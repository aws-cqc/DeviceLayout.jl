@testitem "Channels" setup = [CommonTestSetup] begin
    import DeviceLayout.Paths: RouteChannel
    using .SchematicDrivenLayout

    function test_single_channel_reversals(r, seg, sty)
        paths = test_single_channel(r, seg, sty; reverse_channel=false, reverse_paths=false)
        paths_revch =
            test_single_channel(r, seg, sty; reverse_channel=true, reverse_paths=false)
        paths_revp =
            test_single_channel(r, seg, sty; reverse_channel=false, reverse_paths=true)
        paths_rev_ch_p =
            test_single_channel(r, seg, sty; reverse_channel=true, reverse_paths=true)
        # Segments are approximately the same when channel is reversed
        for (pa1, pa2) in zip(paths, paths_revch)
            for (n1, n2) in zip(pa1, pa2)
                @test p0(n1.seg) ≈ p0(n2.seg) atol = 1nm
                @test p1(n1.seg) ≈ p1(n2.seg) atol = 1nm
                @test isapprox_angle(α0(n1.seg), α0(n2.seg), atol=1e-6)
                @test isapprox_angle(α1(n1.seg), α1(n2.seg), atol=1e-6)
                @test pathlength(n1.seg) ≈ pathlength(n2.seg) atol = 1nm
            end
        end
        for (pa1, pa2) in zip(paths_revp, paths_rev_ch_p)
            for (n1, n2) in zip(pa1, pa2)
                @test p0(n1.seg) ≈ p0(n2.seg) atol = 1nm
                @test p1(n1.seg) ≈ p1(n2.seg) atol = 1nm
                @test isapprox_angle(α0(n1.seg), α0(n2.seg), atol=1e-6)
                @test isapprox_angle(α1(n1.seg), α1(n2.seg), atol=1e-6)
                @test pathlength(n1.seg) ≈ pathlength(n2.seg) atol = 1nm
            end
        end
        # Segments are approximately reversed when paths are reversed
        for (pa1, pa2) in zip(paths, paths_revp)
            for (n1, n2) in zip(pa1, reverse(pa2.nodes))
                @test p0(n1.seg) ≈ p1(n2.seg) atol = 1nm
                @test p1(n1.seg) ≈ p0(n2.seg) atol = 1nm
                @test isapprox_angle(α0(n1.seg), α1(n2.seg) + 180°, atol=1e-6)
                @test isapprox_angle(α1(n1.seg), α0(n2.seg) + 180°, atol=1e-6)
                @test pathlength(n1.seg) ≈ pathlength(n2.seg) atol = 1nm
                # Some reversed paths are visibly different with taper trace and auto_speed (1um length difference)
                # because the asymmetry causes speed optimization to find a different optimum
                # depending on which is t0 and which is t1. So we use manual speed
                # (also because it runs faster and we don't need to test auto further)
            end
        end
        return paths
    end

    function test_single_channel(
        transition_rule,
        channel_segment,
        channel_style;
        reverse_channel=false,
        reverse_paths=false
    )
        channel = Path(0.0μm, 0.0μm)
        if channel_segment == Paths.Straight
            straight!(channel, 1mm, channel_style)
        elseif channel_segment == Paths.Turn
            if channel_style isa Paths.TaperTrace
                # This path is not simplified, and tapers inside CompoundStyle are not supported for channels
                return Path[]
            end
            turn!(channel, 0.04, 10mm, channel_style)
            turn!(channel, -0.06, 10mm, channel_style)
        elseif channel_segment == Paths.CompoundSegment
            turn!(channel, 90°, 0.25mm, channel_style)
            turn!(channel, -90°, 0.25mm)
            turn!(channel, -90°, 0.25mm)
            turn!(channel, 90°, 0.25mm)
            simplify!(channel)
            setstyle!(channel[1], channel_style)
        elseif channel_segment == Paths.BSpline
            bspline!(
                channel,
                [Point(0.5, 0.5)mm, Point(1.0mm, 0.0μm)],
                0°,
                channel_style,
                auto_speed=true,
                auto_curvature=true
            )
        end

        reverse_channel && (channel = Path(reverse(reverse.(channel.nodes))))

        # Variety of cases
        p0s = [
            Point(100.0, 200.0)μm,    # Enter and exit from top
            Point(50.0, 150)μm,      # Enter from top, exit from right
            Point(-100.0, 100.0)μm,  # Enter from upper left, exit from right
            Point(-100.0, 0.0)μm,    # Centered
            Point(-100.0, -100.0)μm, # Enter from lower left, exit from right
            Point(50.0, -150)μm,     # Enter from bottom, exit from right
            Point(100.0, -200.0)μm  # Enter and exit from bottom
        ]

        p1s = [
            Point(900.0, 200.0)μm,
            Point(1100.0, 150.0)μm,
            Point(1100.0, 100.0)μm,
            Point(1100.0, 0.0)μm,
            Point(1100.0, -100.0)μm,
            Point(1100.0, -150.0)μm,
            Point(900.0, -200.0)μm
        ]
        reverse_paths && ((p0s, p1s) = (p1s, p0s))

        α0s = fill(reverse_paths ? 180.0° : 0.0°, length(p0s))
        α1s = copy(α0s)

        paths = [Path(p, α0=α0) for (p, α0) in zip(p0s, α0s)]
        tracks = reverse_channel ? reverse(eachindex(paths)) : eachindex(paths)

        rule =
            Paths.SingleChannelRouting(Paths.RouteChannel(channel), transition_rule, 50.0μm)
        setindex!.(Ref(rule.segment_tracks), tracks, paths)
        for (pa, p1, α1) in zip(paths, p1s, α1s)
            route!(pa, p1, α1, rule, Paths.Trace(2μm))
        end
        return paths
    end

    function test_schematic_single_channel()
        g = SchematicGraph("test")
        pa = Path(0.0nm, 0.0nm)
        straight!(pa, 1mm, Paths.Trace(300μm))
        ch = Paths.RouteChannel(pa)
        spacer1 = add_node!(g, Spacer(-1mm, 1mm, name="s1"))
        spacer2 = add_node!(g, Spacer(1mm, 1mm, name="s2"))
        spacer3 = add_node!(g, Spacer(-500μm, 500μm, name="s3"))
        fuse!(g, spacer3 => :p1_west, ch => :p0)
        rule = Paths.SingleChannelRouting(ch, Paths.StraightAnd90(50μm), 0μm)
        r1 = route!(
            g,
            rule,
            spacer1 => :p1_west,
            spacer2 => :p1_east,
            Paths.CPW(1μm, 1μm),
            GDSMeta()
        )
        r2 = route!(
            g,
            rule,
            spacer1 => :p1_west,
            spacer2 => :p1_east,
            Paths.SimpleTrace(1μm),
            GDSMeta()
        )
        sch = plan(g; log_dir=nothing) # channel global coordinate update happens in plan
        pa1 = SchematicDrivenLayout.path(r1.component)
        pa2 = SchematicDrivenLayout.path(r2.component)
        # Track assignment means pa1 track is 100um above pa2 track
        @test pathlength(pa1) ≈ 2 * (350μm + pi * 50μm + 0.4mm) + 1mm atol = 1nm
        @test pathlength(pa2) ≈ 2 * (450μm + pi * 50μm + 0.4mm) + 1mm atol = 1nm
        c = Cell("test", nm)
        return render!(c, pa1, GDSMeta()) # No error
    end

    ### Single-channel integration tests
    ## Geometry-level routing
    transition_rules = [
        Paths.StraightAnd90(min_bend_radius=25μm)
        Paths.BSplineRouting(endpoints_speed=150μm, auto_curvature=true)
    ]
    channel_segments = [Paths.Straight, Paths.Turn, Paths.BSpline, Paths.CompoundSegment]
    channel_styles = [Paths.Trace(100μm), Paths.TaperTrace(100μm, 50μm)]
    # StraightAnd90 only works with straight channel and simple trace
    @testset "Straight" begin
        rule = transition_rules[1]
        paths = test_single_channel_reversals(rule, channel_segments[1], channel_styles[1])
        @test isempty(Intersect.intersections(paths...))
        c = Cell("test", nm)
        render!(c, paths[1], GDSMeta()) # No error
    end
    rule = transition_rules[2] # BSpline rule for all-angle transitions
    for segtype in channel_segments[2:end]
        for sty in channel_styles
            @testset "$segtype, $sty channel" begin
                test_single_channel_reversals(rule, segtype, sty)
            end
        end
    end
    # Channel too short
    pa = Path(0.0nm, 0.0nm)
    straight!(pa, 100nm, Paths.Trace(0.1mm))
    ch = RouteChannel(pa)
    pa2 = Path(-0.1mm, 0mm)
    rule = Paths.SingleChannelRouting(
        ch,
        Paths.BSplineRouting(auto_curvature=true, auto_speed=true),
        50μm
    )
    Paths.set_track!(rule, pa2, 1)
    route!(pa2, Point(0.1mm, 0.1mm), 0, rule, Paths.CPW(2nm, 2nm))
    @test length(pa2) == 1 # Channel segment turned into waypoint

    # Pathlength is arclength
    pa = Path(0.0nm, 0.0nm)
    turn!(pa, 90°, 1mm, Paths.Trace(0.3mm))
    ch = RouteChannel(pa)
    pa2 = Path(-1mm, 0mm)
    pa3 = Path(-1mm, 0mm)
    rule = Paths.SingleChannelRouting(ch, Paths.StraightAnd90(5μm), 0μm)
    Paths.set_track!(rule, pa2, 1)
    Paths.set_track!(rule, pa3, 2)
    route!(pa2, Point(1mm, 2mm), pi / 2, rule, Paths.CPW(2nm, 2nm))
    route!(pa3, Point(1mm, 2mm), pi / 2, rule, Paths.CPW(2nm, 2nm))

    @test pathlength(pa2[7]) == pi / 2 * (1mm - 0.05mm)
    @test pathlength(pa3[7]) == pi / 2 * (1mm + 0.05mm)

    # Unit test Compound GeneralOffset resolution
    pa = Path(0, 0)
    straight!(pa, 2, Paths.CPW(2, 2))
    straight!(pa, 1, Paths.CPW(2, 2))
    simplify!(pa)
    pa[1].seg = Paths.offset(pa[1].seg, x -> x^2)
    resolved = Paths.resolve_offset(pa[1].seg)
    @test p1(resolved.segments[1]) == Point(2, 4)
    @test p1(resolved.segments[2]) == Point(3, 9)

    ## Schematic-level routing
    test_schematic_single_channel()
end

@testitem "Channel Autorouter" setup = [CommonTestSetup] begin
    import DeviceLayout.Paths: RouteChannel, ChannelRouter
    using .SchematicDrivenLayout

    function test_simple(; split=false)

        mypins = [
            Point(4.0, 3.0),
            Point(6.0, 3.0),
            Point(4.0, 7.0),
            Point(6.0, 7.0),
            Point(3.0, 4.0),
            Point(3.0, 6.0),
            Point(7.0, 4.0),
            Point(7.0, 6.0)
        ]
        dirs = [0, pi, 0, pi, pi / 2, -pi / 2, pi / 2, -pi / 2] .+ pi
        pins = PointHook.(mypins, dirs)

        space_paths = Path[]
        for x0 in [1.0, 5.0, 9.0]
            pa = Path(x0, 0.0, α0=90°)
            if split && x0 == 5.0
                straight!(pa, 4.5, Paths.Trace(2.0))
                push!(space_paths, pa)
                pa = Path(x0, 5.5, α0=90°)
                straight!(pa, 4.5, Paths.Trace(2.0))
                push!(space_paths, pa)
                continue
            end
            straight!(pa, 10.0, Paths.Trace(2.0))
            push!(space_paths, pa)
        end
        for y0 in [1.0, 5.0, 9.0]
            pa = Path(0.0, y0)
            if split && y0 == 5.0
                pa = Path(0.0, y0+0.7)
                straight!(pa, 10.0, Paths.Trace(1.0))
                push!(space_paths, pa)
                pa = Path(0.0, y0-0.7)
                straight!(pa, 10.0, Paths.Trace(1.0))
                push!(space_paths, pa)
                continue
            end
            straight!(pa, 10.0, Paths.Trace(2.0))
            push!(space_paths, pa)
        end

        n_wires = 4
        mynets = [(i, i + 4) for i = 1:n_wires]
        ar = ChannelRouter(
            mynets,
            pins,
            RouteChannel.(space_paths)
        )


        # # # # Split space demo
        # # # Cut space 2 in half
        # # pin_adjoining_spaces = [2, 2, 4, 4, 8, 6, 8, 6]
        # # space_coord = [1.0, 5.0, 9.0, 5.0, 1.0, 5.5, 9.0, 4.5]
        # # space_coord_idx = [1, 1, 1, 1, 2, 2, 2, 2]
        # # space_widths = [2.0, 2.0, 2.0, 2.0, 2.0, 1.0, 2.0, 1.0]

        # # # Split space demo
        # # 2 doesn't connect to upper half of horizontal spaces
        # rem_edge!(ar.space_graph, 2, 6)
        # rem_edge!(ar.space_graph, 2, 7)
        # # 4 (other half of 2) doesn't connect to bottom half
        # rem_edge!(ar.space_graph, 4, 5)
        # rem_edge!(ar.space_graph, 4, 8)

        Paths.assign_channels!(ar) #, fixed_paths=Dict(2=>[2, 8, 4, 6]))
        Paths.assign_tracks!(ar)

        rule = Paths.StraightAnd90(min_bend_radius=0.1, max_bend_radius=0.1)
        # rule = Paths.StraightAnd45(min_bend_radius=0.1, max_bend_radius=0.1)
        # rule = Paths.BSplineRouting(endpoints_speed=7.5)
        # rts = make_routes!(ar, rule)
        # paths = [Path(rt, Paths.Trace(0.1)) for rt in rts]

        c = Paths.visualize_router_state(ar);

        save("autoroute_test.svg", c, width=10DeviceLayout.Graphics.inch)
        return c
    end

    function test_fanout()
        lx_outer = ly_outer = 10e6nm
        lx_inner = ly_inner = 5e6nm

        fanout_space_bottom = Path(Point(-lx_outer/2, -(ly_inner/2 + (ly_outer - ly_inner)/4)))
        straight!(fanout_space_bottom, lx_outer, Paths.Trace(0.8*(ly_outer - ly_inner)/4))

        n_nets = 40
        x0s = range(-lx_outer/2, stop=lx_outer/2, length=n_nets+2)[2:end-1]
        x1s = range(-lx_inner/2, stop=lx_inner/2, length=n_nets+2)[2:end-1]
        p0s = [PointHook(x, -ly_outer/2, -90°) for x in x0s]
        p1s = [PointHook(x, -ly_inner/2, 90°) for x in x1s]
        # n_nets=10
        mynets = [(i, i + n_nets) for i = 1:n_nets]
        ar = ChannelRouter(
            mynets,
            vcat(p0s, p1s),
            [RouteChannel(fanout_space_bottom)]
        )

        Paths.assign_channels!(ar)
        Paths.assign_tracks!(ar)

        c = Paths.visualize_router_state(ar);

        save("autoroute_test.png", c, width=10DeviceLayout.Graphics.inch)
        return c
    end
    function test_grid_escape()
        # Grid of sites
        dx = 1.5
        dy = 1.5
        nx = 20
        ny = 20
        grid = [(ix, iy) for ix in 1:nx for iy in 1:ny]
        sites = [Point(dx * (ix - 1), dy * (iy - 1)) for (ix, iy) in grid]
        site_size = 0.5

        # Channel coordinates
        n_xch = nx + 1   # vertical channels
        n_ych = ny + 1   # horizontal channels
        x_coords = range(-dx / 2, step=dx, length=n_xch)
        y_coords = range(-dy / 2, step=dy, length=n_ych)

        # Build channel Paths (vertical then horizontal)
        # Margin ensures channels cross each other but don't extend to edge pin positions
        margin = 0.5
        space_paths = Path[]
        for x in x_coords
            pa = Path(x, first(y_coords) - margin, α0=90°)
            straight!(pa, last(y_coords) - first(y_coords) + 2margin, Paths.Trace(1.0))
            push!(space_paths, pa)
        end
        for y in y_coords
            pa = Path(first(x_coords) - margin, y)
            straight!(pa, last(x_coords) - first(x_coords) + 2margin, Paths.Trace(1.0))
            push!(space_paths, pa)
        end

        # Site pins: each site escapes toward the nearest grid edge
        site_dirs = map(grid) do (ix, iy)
            ix_delta = ix - nx / 2
            iy_delta = iy - ny / 2
            if abs(ix_delta) > abs(iy_delta)
                return ix_delta > 0 ? 0.0 : pi
            end
            return iy_delta > 0 ? pi / 2 : -pi / 2
        end
        site_pin_pos = [
            site + 0.5site_size * Point(cos(d), sin(d))
            for (site, d) in zip(sites, site_dirs)
        ]
        # PointHook in_direction points inward (away from channel); site_dirs point toward channel
        site_hooks = [PointHook(p, d + pi) for (p, d) in zip(site_pin_pos, site_dirs)]

        # Edge pins: placed at grid boundary, one per site
        edge_dirs = [rem2pi(d + pi, RoundNearest) for d in site_dirs]

        # Edge geometry: fixed coordinate and orientation for each of 4 edges
        edge_fixed = [first(x_coords), last(x_coords), first(y_coords), last(y_coords)]
        edge_is_vertical = [true, true, false, false]
        function edge_index(dir)
            abs(dir) < 0.1 && return 1                          # left edge (dir ≈ 0)
            abs(abs(dir) - pi) < 0.1 && return 2                # right edge (dir ≈ ±π)
            abs(dir - pi / 2) < 0.1 && return 3                 # bottom edge (dir ≈ π/2)
            return 4                                              # top edge (dir ≈ -π/2)
        end

        # Pre-compute edge assignments and per-edge coordinate ranges
        edge_assignments = [edge_index(edir) for edir in edge_dirs]
        pins_per_edge = [count(==(ei), edge_assignments) for ei in 1:4]
        coord_span = (-dx / 2, -dx / 2 + nx * dx)
        coord_ranges = [range(coord_span..., length=n) for n in pins_per_edge]

        edge_count = [1, 1, 1, 1]
        edge_hooks = map(zip(edge_dirs, edge_assignments)) do (edir, ei)
            ci = edge_count[ei]
            edge_count[ei] += 1
            fixed = edge_fixed[ei]
            c = coord_ranges[ei][ci]
            pos = if edge_is_vertical[ei]
                Point(fixed - cos(edir), c)
            else
                Point(c, fixed - sin(edir))
            end
            return PointHook(pos, edir + pi)
        end

        # Assemble: each site pin connects to its corresponding edge pin
        all_hooks = [site_hooks; edge_hooks]
        n_wires = length(sites)
        mynets = [(i, i + n_wires) for i in 1:n_wires]

        ar = ChannelRouter(
            mynets,
            all_hooks,
            RouteChannel.(space_paths)
        )

        Paths.assign_channels!(ar)
        Paths.assign_tracks!(ar)

        c = Paths.visualize_router_state(ar, wire_width=0.001)
        save("autoroute_escape_test.gds", c)
        return c
    end
    # Runs without error
    test_simple()
    test_fanout()
    test_grid_escape()
end
