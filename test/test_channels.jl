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
    @testset "B-spline channel-section endpoint clamping" begin
        channel = Path(0.0μm, 0.0μm)
        bspline!(
            channel,
            [Point(0.5, 0.5)mm, Point(1.0mm, 0.0μm)],
            0°,
            Paths.Trace(100μm),
            auto_speed=true,
            auto_curvature=true
        )
        ch = RouteChannel(channel)
        L = pathlength(ch.node.seg)
        start = L / 4

        section = Paths.segment_channel_section(ch, start, L + 1μm, 0μm, 0μm)
        @test p0(section.seg) ≈ ch.node.seg(start) atol = 1nm
        @test p1(section.seg) ≈ p1(ch.node.seg) atol = 1nm

        reversed_section = Paths.segment_channel_section(ch, L + 1μm, start, 0μm, 0μm)
        @test p0(reversed_section.seg) ≈ p1(ch.node.seg) atol = 1nm
        @test p1(reversed_section.seg) ≈ ch.node.seg(start) atol = 1nm

        for (wireseg_start, wireseg_stop, expected_point) in (
            (-2μm, -1μm, p0(ch.node.seg)),
            (-1μm, -2μm, p0(ch.node.seg)),
            (L + 1μm, L + 2μm, p1(ch.node.seg)),
            (L + 2μm, L + 1μm, p1(ch.node.seg))
        )
            clamped_section =
                Paths.segment_channel_section(ch, wireseg_start, wireseg_stop, 0μm, 0μm)
            @test iszero(pathlength(clamped_section.seg))
            @test p0(clamped_section.seg) ≈ expected_point atol = 1nm
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

    @testset "compound resolve_offset propagates atol" begin
        pb = Path(0nm, 0nm)
        straight!(pb, 100μm, Paths.SimpleTrace(10μm))
        bspline!(pb, [Point(300μm, 200μm), Point(500μm, 0μm)], 0°, Paths.SimpleTrace(10μm))
        simplify!(pb)
        off = Paths.offset(pb[1].seg, 5μm)
        # Tighter atol must reach the BSpline fallback inside the compound segment.
        count_bspline(s) =
            s isa Paths.BSpline ? length(s.p) :
            (s isa Paths.CompoundSegment ? sum(count_bspline.(s.segments); init=0) : 0)
        n_loose = count_bspline(Paths.resolve_offset(off; atol=5μm))
        n_tight = count_bspline(Paths.resolve_offset(off; atol=1nm))
        @test n_tight > n_loose
    end

    ## reverse(::OffsetSegment) tests
    @testset "reverse ConstantOffset" begin
        seg = Paths.Straight(10.0μm)
        offset_seg = Paths.offset(seg, 2.0μm)
        rev = reverse(offset_seg)
        # Type preserved
        @test typeof(rev) === typeof(offset_seg)
        # Pathlength preserved
        @test Paths.arclength(rev) ≈ Paths.arclength(offset_seg)
        @test pathlength(rev) ≈ pathlength(offset_seg)
        # Offset negated
        @test Paths.getoffset(rev) ≈ -2.0μm
        # Endpoints swapped: p0 of reversed ≈ p1 of original
        @test p0(rev) ≈ p1(offset_seg) atol = 0.01nm
        @test p1(rev) ≈ p0(offset_seg) atol = 0.01nm
        # Round-trip: reverse(reverse(seg)) ≈ original
        roundtrip = reverse(rev)
        @test p0(roundtrip) ≈ p0(offset_seg) atol = 0.01nm
        @test p1(roundtrip) ≈ p1(offset_seg) atol = 0.01nm
        @test Paths.getoffset(roundtrip) ≈ 2.0μm
    end

    @testset "reverse ConstantOffset Turn" begin
        seg = Paths.Turn(90°, 50.0μm)
        offset_seg = Paths.offset(seg, 5.0μm)
        rev = reverse(offset_seg)
        @test typeof(rev) === typeof(offset_seg)
        @test Paths.arclength(rev) ≈ Paths.arclength(offset_seg)
        @test pathlength(rev) == pathlength(offset_seg)
        @test Paths.getoffset(rev) ≈ -5.0μm
        @test p0(rev) ≈ p1(offset_seg) atol = 0.01nm
        @test p1(rev) ≈ p0(offset_seg) atol = 0.01nm
    end

    @testset "reverse ConstantOffset BSpline" begin
        pa = Path(0.0μm, 0.0μm)
        bspline!(pa, [Point(0.5, 0.5)mm, Point(1.0mm, 0.0mm)], -90°, Paths.Trace(0.1mm))
        seg = pa[1].seg
        offset_seg = Paths.offset(seg, 300.0μm)
        rev = reverse(offset_seg)
        @test Paths.arclength(rev) ≈ Paths.arclength(offset_seg)
        @test Paths.pathlength(rev) ≈ Paths.pathlength(offset_seg)
        @test p0(rev) ≈ p1(offset_seg) atol = 0.1nm
        @test p1(rev) ≈ p0(offset_seg) atol = 0.1nm
    end

    @testset "reverse GeneralOffset" begin
        seg = Paths.Turn(90°, 50.0μm)
        l = pathlength(seg)
        offset_fn = t -> t / 10  # linear offset: 0 at start, 1μm at end
        offset_seg = Paths.offset(seg, offset_fn)
        rev = reverse(offset_seg)
        # Type preserved
        @test typeof(rev) === typeof(offset_seg)
        # Pathlength preserved
        @test Paths.arclength(rev) ≈ Paths.arclength(offset_seg)
        @test pathlength(rev) == pathlength(offset_seg)
        # Offset function is remapped: at t=0 of reversed, should get negated original end value
        @test Paths.getoffset(rev, 0.0μm) ≈ -Paths.getoffset(offset_seg, l) atol = 0.001nm
        @test Paths.getoffset(rev, l) ≈ -Paths.getoffset(offset_seg, 0.0μm) atol = 0.001nm
        # Endpoints swapped
        @test p0(rev) ≈ p1(offset_seg) atol = 0.1nm
        @test p1(rev) ≈ p0(offset_seg) atol = 0.1nm
    end

    ## Schematic-level routing
    test_schematic_single_channel()
end

@testitem "Channel Autorouter" setup = [CommonTestSetup] begin
    import DeviceLayout.Paths: RouteChannel, ChannelRouter
    using .SchematicDrivenLayout

    function test_simple()
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
            straight!(pa, 10.0, Paths.Trace(2.0))
            push!(space_paths, pa)
        end
        for y0 in [1.0, 5.0, 9.0]
            pa = Path(0.0, y0)
            straight!(pa, 10.0, Paths.Trace(2.0))
            push!(space_paths, pa)
        end

        n_wires = 4
        mynets = [(i, i + 4) for i = 1:n_wires]
        ar = ChannelRouter(mynets, pins, RouteChannel.(space_paths))

        Paths.assign_channels!(ar)
        Paths.assign_tracks!(ar)

        @test all(!isempty, ar.net_wires)
        for channel in eachindex(ar.channel_segments)
            assigned =
                reduce(vcat, ar.channel_tracks[channel]; init=Paths.TrackWireSegment[])
            @test Set(assigned) == Set(ar.channel_segments[channel])
            @test length(assigned) == length(unique(assigned))
        end

        c = Paths.visualize_router_state(ar)
        return c
    end

    # Runs without error
    test_simple()

    # Fan-out from all four sides of an inner die to the bottom outer edge, via a channel on
    # each side: bottom (B), left (C), right, top, assigned in that order. There are `q`
    # pins per die side and 4q outer pins along the bottom edge, offset by `shift` pin
    # pitches. Many outer pins lie under the side channels, so their segments in B are
    # short jogs whose direction depends on side channel track assignment.
    # Lengths are in units of `u`.
    function perimeter_to_edge_problem(q, shift, u=1)
        lo, li, m = 10.0u, 2.0u, 1.5u
        w_h = lo / 2 - li / 2 - 2m
        w_v = lo / 2 - li / 2 - m
        y_b = -lo / 2 + (lo - li) / 4
        x_l = -lo / 2 + (lo - li) / 4
        bottom = Path(-lo / 2, y_b)
        straight!(bottom, lo, Paths.Trace(w_h))
        top = Path(-lo / 2, -y_b)
        straight!(top, lo, Paths.Trace(w_h))
        left = Path(x_l, y_b, α0=90°)
        straight!(left, lo, Paths.Trace(w_v))
        right = Path(-x_l, y_b, α0=90°)
        straight!(right, lo, Paths.Trace(w_v))

        n = 4q
        side = range(-li / 2, li / 2, length=q + 2)[2:(end - 1)]
        xs = range(-lo / 2, lo / 2, length=n + 2)[2:(end - 1)]
        outer = [PointHook(x + shift * step(xs), -lo / 2, -90°) for x in xs]
        inner = [
            [PointHook(x, li / 2, -90°) for x in reverse(side)]
            [PointHook(-li / 2, y, 0°) for y in reverse(side)]
            [PointHook(x, -li / 2, 90°) for x in side]
            [PointHook(li / 2, y, 180°) for y in side]
        ]
        nets = [(i, i + n) for i = 1:n]
        return nets, [outer; inner], RouteChannel.([bottom, left, right, top])
    end
    function perimeter_to_edge(q, shift; kwargs...)
        ar = ChannelRouter(perimeter_to_edge_problem(q, shift)...)
        routes = Paths.autoroute!(ar, Paths.StraightAnd90(0.01), 0.01; kwargs...)
        paths = Path.(routes, Ref(Paths.Trace(0.01)))
        return filter(Intersect.prepared_intersections(paths)) do ixn
            return ixn[1][1] != ixn[2][1]
        end
    end
    # Refinement must fix orders chosen against side channel centerlines.
    # For example, in the first pass B is assigned before C, so it measures nets 5 and 6
    # to C's centerline (¦). p₅ is just left of it, so net 5 appears to run right and
    # net 6 left. Their runs only touch, so nothing orders their tracks:
    #
    #                  ¦
    #              +-->¦<-----+
    #              |   ¦      |
    #              p₅         p₆
    #
    # Once C is assigned, both turn into C left of p₅, and with net 6 on the lower track
    # in B they cross twice (×):
    #
    #        5     6                    5     6
    #        |     |                    |     |
    #        +-----×-+                  |     +-------+
    #              +-×-----+            +-------+     |
    #                |     |                    |     |
    #                p₅    p₆                   p₅    p₆
    #          first pass               after refinement
    @test isempty(@test_logs min_level = Logging.Error perimeter_to_edge(7, 0.2))
    # Without refinement, the outdated order is reported
    @test_logs (:warn, r"did not converge in 0 refinement passes") match_mode = :any perimeter_to_edge(
        7,
        0.2;
        max_refinement_passes=0
    )

    # Refinement must keep a crossing-free order that neighbor tracks don't constrain.
    # After the first pass nets 5 and 6 run along disjoint stretches of B, so B is free
    # to put net 6 on the lower track. Reassigning C must not read that as net 6 entering
    # inside net 5, or it flips them, and net 6's run in B covers p₅:
    #
    #        5       6                  6       5
    #        |       |                  |       |
    #        +---+   |                  |   +---+
    #            |   +-----+            +---×---------+
    #            |         |                |         |
    #            p₅        p₆               p₅        p₆
    #          first pass                 flipped
    @test isempty(@test_logs min_level = Logging.Error perimeter_to_edge(6, -0.4))

    # Shift 0 is omitted because it places an outer pin within a bend radius of a side
    # channel track, which StraightAnd90 cannot route.
    for shift in (-0.4, -0.2, 0.2, 0.4)
        @test isempty(@test_logs min_level = Logging.Error perimeter_to_edge(10, shift))
    end

    # Wires leaving a channel at the same point to opposite sides must be ordered so their
    # legs don't overlap. Here p₁₇ is exactly where net 18 turns into the right channel:
    #
    #          18                    18
    #          |                     |
    #          +-----           -----#
    #     -----+                     #-----
    #          |                     |
    #          p₁₇                   p₁₇
    #      18 above 17         17 above 18: legs overlap (#)
    @test isempty(@test_logs min_level = Logging.Error perimeter_to_edge(5, -0.2))

    # Wires leaving closer together than the track pitch run side by side in the wrong
    # order. That is reported, and those closer than `min_leg_spacing` are ordered instead.
    # A positive `min_leg_spacing` replaces the pitch as the limit for reporting, so nets 3
    # and 4, about 0.113 apart, are reported by default but not with 0.1.
    @test_logs (:warn, r"Nets 6 and 5 leave channel 1 .* opposite sides") match_mode = :any perimeter_to_edge(
        6,
        -0.4
    )
    @test_logs (:warn, r"Nets 3 and 4 .* Set `min_leg_spacing` greater than") match_mode =
        :any perimeter_to_edge(6, -0.4)
    for min_leg_spacing in (0.1, 0.12)
        @test isempty(
            @test_logs min_level = Logging.Warn perimeter_to_edge(6, -0.4; min_leg_spacing)
        )
    end
    # Schematic-level routing takes the options from the rule
    function perimeter_to_edge_schematic(q, shift; kwargs...)
        nets, pins, channels = perimeter_to_edge_problem(q, shift, 1mm)
        g = SchematicGraph("perimeter_to_edge")
        hook_name(α) = only(
            name for (name, β) in
            ((:p1_east, 0°), (:p1_north, 90°), (:p1_west, 180°), (:p1_south, 270°)) if
            Paths.isapprox_angle(α, β)
        )
        nodes = [add_node!(g, Spacer(; p1=pin.p)) for pin in pins]
        rule = Paths.AutoChannelRouting(
            channels,
            Paths.StraightAnd90(0.01mm),
            0.01mm;
            kwargs...
        )
        for (i, j) in nets
            route!(
                g,
                rule,
                nodes[i] => hook_name(pins[i].in_direction),
                nodes[j] => hook_name(pins[j].in_direction),
                Paths.Trace(0.01mm),
                GDSMeta()
            )
        end
        plan(g; log_dir=nothing)
        return rule
    end
    @test_logs (:warn, r"Nets 6 and 5 .* Set `min_leg_spacing` greater than") match_mode =
        :any perimeter_to_edge_schematic(6, -0.4)
    rule = @test_logs min_level = Logging.Warn perimeter_to_edge_schematic(
        6,
        -0.4;
        max_refinement_passes=3,
        min_leg_spacing=120μm
    )
    @test rule.max_refinement_passes == 3
    @test rule.min_leg_spacing ≈ 0.12mm

    # A pin offset from a crossing channel's track by less than StraightAnd90 can jog is
    # reported by net, since the resulting route errors only give coordinates
    function pin_jog_router(offset)
        bottom = Path(0.0, 0.0)
        straight!(bottom, 10.0, Paths.Trace(2.0))
        side = Path(5.0, 0.0, α0=90°)
        straight!(side, 10.0, Paths.Trace(2.0))
        pins = [PointHook(Point(5.0 + offset, -2.0), 270°), PointHook(Point(7.0, 8.0), 0°)]
        return ChannelRouter([(1, 2)], pins, RouteChannel.([bottom, side]))
    end
    @test_logs (:warn, r"Net 1 jogs .* channel 1 between pin 1 and channel 2") Paths.autoroute!(
        pin_jog_router(0.05),
        Paths.StraightAnd90(0.1),
        0.1
    )
    for offset in (0.0, 0.2)
        @test_logs Paths.autoroute!(pin_jog_router(offset), Paths.StraightAnd90(0.1), 0.1)
    end
    # StraightAnd45 makes the jog with a 45° turn on each side, so its minimum is shorter
    @test_logs (:warn, r"Net 1 jogs .* StraightAnd45 needs a jog of zero or at least") Paths.autoroute!(
        pin_jog_router(0.03),
        Paths.StraightAnd45(0.1),
        0.3
    )
    @test_logs Paths.autoroute!(pin_jog_router(0.1), Paths.StraightAnd45(0.1), 0.3)

    # Pins in the same column on opposite sides of a channel keep their order through
    # refinement passes, which see each segment's own track. In a wide channel, its offset
    # must not move the aligned ends apart by rounding error, and pins misaligned by
    # rounding error must still count as aligned.
    function aligned_column_router(dx)
        channel = Path(0.0, 0.0)
        straight!(channel, 200.0, Paths.Trace(100.0))
        pins = [
            PointHook(Point(2.0, 60.0), 90°),
            PointHook(Point(10.0, -60.0), -90°),
            PointHook(Point(10.0 + dx, 60.0), 90°),
            PointHook(Point(50.0, -60.0), -90°)
        ]
        ar = ChannelRouter([(1, 2), (3, 4)], pins, [RouteChannel(channel)])
        Paths.assign_channels!(ar)
        return ar
    end
    for dx in (0.0, 1e-12, -1e-12), passes = 0:4
        ar = aligned_column_router(dx)
        @test_logs Paths.assign_tracks!(ar; max_refinement_passes=passes)
        @test [Paths.segment_track(ar, only(Paths.net_wire(ar, n))) for n = 1:2] == [2, 1]
    end
    @test_throws ArgumentError Paths.assign_tracks!(
        aligned_column_router(0.0);
        max_refinement_passes=-1
    )

    # A pair that track assignment orders but that ends up in the wrong order is reported
    # as conflicting with other track constraints. Reversing the tracks stands in for such
    # a conflict.
    ar = aligned_column_router(0.0)
    Paths.assign_tracks!(ar)
    reverse!(Paths.channel_tracks(ar, 1))
    @test_logs (
        :warn,
        r"Nets 2 and 1 leave channel 1 at the same point .* overlaps .* conflicts with other"
    ) Paths._warn_close_legs(ar, 0.0)
    ar = aligned_column_router(1.0)
    Paths.assign_tracks!(ar; min_leg_spacing=5.0)
    @test [Paths.segment_track(ar, only(Paths.net_wire(ar, n))) for n = 1:2] == [2, 1]
    reverse!(Paths.channel_tracks(ar, 1))
    @test_logs (
        :warn,
        r"Nets 2 and 1 leave channel 1 1.0 apart .* `min_leg_spacing` 5.0. .* conflicts"
    ) Paths._warn_close_legs(ar, 5.0)

    # Zones are ordered left to right by their maximal elements, which are distinct. Net 4's
    # segment (20–117) is the minimal element of several zones, so ordering by minimal
    # elements would leave those unordered and merge overlapping nets 3 (96–103) and 5
    # (101–188) onto one track.
    function zone_order_router()
        channel = Path(0.0, 0.0)
        straight!(channel, 200.0, Paths.Trace(100.0))
        top(x) = PointHook(Point(x, 60.0), 90°)
        bottom(x) = PointHook(Point(x, -60.0), -90°)
        pins = [
            bottom(142.0),
            bottom(185.0),
            top(59.0),
            bottom(37.0),
            top(96.0),
            top(103.0),
            top(20.0),
            bottom(117.0),
            top(101.0),
            bottom(188.0)
        ]
        nets = [(2i - 1, 2i) for i = 1:5]
        ar = ChannelRouter(nets, pins, [RouteChannel(channel)])
        Paths.assign_channels!(ar)
        return ar
    end
    ar = zone_order_router()
    Paths.assign_tracks!(ar)
    @test Paths._shared_track_overlaps(ar) == 0
    @test Paths.num_tracks(ar, 1) == 3

    # Ten nets fan out from inner pins above a channel at a pitch of 1 to outer pins below
    # it at a pitch of 2. Each half is a staircase of tracks, and the halves share them. The
    # legs of the center nets 5 and 6 are half a pitch from those of nets 4 and 7 unless
    # they go below them. With `min_leg_spacing` 1 they do, on a fifth track that they
    # share, and the halves still share the other four.
    function fanout_router()
        channel = Path(-11.0, 0.0)
        straight!(channel, 22.0, Paths.Trace(4.0))
        outer = [PointHook(Point(2.0 * i - 11, -3.0), -90°) for i = 1:10]
        inner = [PointHook(Point(i - 5.5, 3.0), 90°) for i = 1:10]
        nets = [(i, i + 10) for i = 1:10]
        ar = ChannelRouter(nets, [outer; inner], [RouteChannel(channel)])
        Paths.assign_channels!(ar)
        return ar
    end
    ar = fanout_router()
    @test_logs Paths.assign_tracks!(ar; min_leg_spacing=1.0)
    @test Paths.num_tracks(ar, 1) == 5
    @test [Paths.segment_track(ar, only(Paths.net_wire(ar, n))) for n = 4:7] == [4, 5, 5, 4]

    # A 3×3 grid of channels 4 wide at a pitch of 10, with nets between consecutive pins
    # given as `(x, y, direction in degrees)`
    function grid_router(pins)
        channels = Path{Float64}[]
        for y in (0.0, 10.0, 20.0)
            pa = Path(-5.0, y)
            straight!(pa, 30.0, Paths.Trace(4.0))
            push!(channels, pa)
        end
        for x in (0.0, 10.0, 20.0)
            pa = Path(x, -5.0, α0=90°)
            straight!(pa, 30.0, Paths.Trace(4.0))
            push!(channels, pa)
        end
        hooks = [PointHook(Point(x, y), α * °) for (x, y, α) in pins]
        nets = [(2i - 1, 2i) for i = 1:(length(pins) ÷ 2)]
        ar = ChannelRouter(nets, hooks, RouteChannel.(channels))
        Paths.assign_channels!(ar)
        return ar
    end
    # Channels whose constraints depend on each other's tracks can trade assignments from
    # pass to pass without settling. From the second refinement pass on, a channel keeps
    # tracks that still satisfy its constraints, which here settles on three tracks in
    # channel 1. The initial pass also satisfies its constraints, but with four.
    ar = grid_router([
        (26.0, 20.44, 0),
        (0.2, 26.0, 90),
        (26.0, 6.53, 0),
        (9.82, -6.0, -90),
        (5.16, 26.0, 90),
        (26.0, 24.11, 0),
        (19.65, -6.0, -90),
        (26.0, 16.46, 0),
        (-0.51, -6.0, -90),
        (26.0, -4.33, 0),
        (6.03, -6.0, -90),
        (26.0, 6.9, 0)
    ])
    @test_logs Paths.assign_tracks!(ar)
    @test isempty(Paths._violating_channels(ar, 0.0))
    @test Paths.num_tracks(ar, 1) == 3
    # If refinement doesn't settle, the assignment tried with the fewest violations is
    # kept. Here the last pass leaves two wires overlapping on a shared track, but the
    # initial pass satisfies all constraints, so it is kept without a warning.
    ar = grid_router([
        (-0.73, -6.0, -90),
        (20.45, -6.0, -90),
        (6.93, -6.0, -90),
        (23.65, 26.0, 90),
        (26.0, 9.18, 0),
        (-6.0, 0.14, 180),
        (-6.0, 10.47, 180),
        (0.03, -6.0, -90),
        (2.31, -6.0, -90),
        (15.67, 26.0, 90),
        (3.36, -6.0, -90),
        (-6.0, 23.97, 180)
    ])
    @test_logs Paths.assign_tracks!(ar)
    @test isempty(Paths._violating_channels(ar, 0.0))
    # Refinement can also cycle between assignments, which more passes won't settle. The
    # warning says which, and the assignment kept has no wires overlapping on a track.
    cycling_pins = [
        (-6.0, -0.64, 180),
        (-6.0, 4.03, 180),
        (-6.0, 17.58, 180),
        (-6.0, 4.14, 180),
        (26.0, 7.81, 0),
        (21.62, -6.0, -90),
        (26.0, 5.8, 0),
        (-1.09, 26.0, 90),
        (-6.0, 19.81, 180),
        (7.27, 26.0, 90),
        (9.03, 26.0, 90),
        (-6.0, 21.17, 180),
        (26.0, 7.2, 0),
        (-6.0, -2.78, 180),
        (-4.19, 26.0, 90),
        (14.47, 26.0, 90),
        (26.0, 9.99, 0),
        (-1.59, 26.0, 90)
    ]
    ar = grid_router(cycling_pins)
    @test_logs (:warn, r"in 2 refinement passes.* channels \[3\] .* may help") Paths.assign_tracks!(
        ar
    )
    ar = grid_router(cycling_pins)
    @test_logs (:warn, r"in 3 refinement passes.* cycle between assignments") Paths.assign_tracks!(
        ar;
        max_refinement_passes=4
    )
    @test Paths._shared_track_overlaps(ar) == 0
    @test_throws ArgumentError Paths.AutoChannelRouting(
        ar,
        Paths.StraightAnd90(0.1),
        0.1;
        max_refinement_passes=-1
    )
end
