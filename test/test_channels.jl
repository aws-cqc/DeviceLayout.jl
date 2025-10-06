import DeviceLayout.Paths: RouteChannel

function test_single_channel_reversals(r, seg, sty)    
    paths = test_single_channel(r, seg, sty;
        reverse_channel=false, reverse_paths=false)
    paths_revch = test_single_channel(r, seg, sty;
        reverse_channel=true, reverse_paths=false)
    paths_revp = test_single_channel(r, seg, sty;
        reverse_channel=false, reverse_paths=true)
    paths_rev_ch_p = test_single_channel(r, seg, sty;
        reverse_channel=true, reverse_paths=true)
    # Segments are approximately the same when channel is reversed
    for (pa1, pa2) in zip(paths, paths_revch)
        for (n1, n2) in zip(pa1, pa2)
            @test p0(n1.seg) ≈ p0(n2.seg) atol=1nm
            @test p1(n1.seg) ≈ p1(n2.seg) atol=1nm
            @test isapprox_angle(α0(n1.seg), α0(n2.seg), atol=1e-6)
            @test isapprox_angle(α1(n1.seg), α1(n2.seg), atol=1e-6)
            @test pathlength(n1.seg) ≈ pathlength(n2.seg) atol=1nm
        end
    end
    for (pa1, pa2) in zip(paths_revp, paths_rev_ch_p)
        for (n1, n2) in zip(pa1, pa2)
            @test p0(n1.seg) ≈ p0(n2.seg) atol=1nm
            @test p1(n1.seg) ≈ p1(n2.seg) atol=1nm
            @test isapprox_angle(α0(n1.seg), α0(n2.seg), atol=1e-6)
            @test isapprox_angle(α1(n1.seg), α1(n2.seg), atol=1e-6)
            @test pathlength(n1.seg) ≈ pathlength(n2.seg) atol=1nm
        end
    end
    # Segments are approximately reversed when paths are reversed
    for (pa1, pa2) in zip(paths, paths_revp)
        for (n1, n2) in zip(pa1, reverse(pa2.nodes))
            @test p0(n1.seg) ≈ p1(n2.seg) atol=1nm
            @test p1(n1.seg) ≈ p0(n2.seg) atol=1nm
            @test isapprox_angle(α0(n1.seg), α1(n2.seg) + 180°, atol=1e-6)
            @test isapprox_angle(α1(n1.seg), α0(n2.seg) + 180°, atol=1e-6)
            @test pathlength(n1.seg) ≈ pathlength(n2.seg) atol=1nm
            # Some reversed paths are visibly different with taper trace and auto_speed (1um length difference)
            # because the asymmetry causes speed optimization to find a different optimum
            # depending on which is t0 and which is t1. So we use manual speed
            # (also because it runs faster and we don't need to test auto further)
        end
    end
    return paths
end

function test_single_channel(transition_rule, channel_segment, channel_style;
        reverse_channel=false, reverse_paths=false)
    channel = Path(0.0μm, 0.0μm)
    if channel_segment == Paths.Straight
        straight!(channel, 1mm, channel_style)
    elseif channel_segment == Paths.Turn
        turn!(channel, 0.1, 10mm, channel_style)
    elseif channel_segment == Paths.CompoundSegment
        turn!(channel, 90°, 0.25mm, channel_style)
        turn!(channel, -90°, 0.25mm)
        turn!(channel, -90°, 0.25mm)
        turn!(channel, 90°, 0.25mm)
        simplify!(channel)
        setstyle!(channel[1], channel_style)
    elseif channel_segment == Paths.BSpline
        bspline!(channel, [Point(0.5, 0.5)mm, Point(1.0mm, 0.0μm)], 0°, channel_style, auto_speed=true, auto_curvature=true)
    end
        
    reverse_channel && (channel = Path([reverse(channel[1])]))

    p0s = [
        Point(100.0, -200.0)μm,
        Point(50.0, -150)μm,
        Point(-100.0, -100.0)μm,
        Point(-100.0, 0.0)μm,
        Point(-100.0, 100.0)μm,
        Point(50.0, 150)μm,
        Point(100.0, 200.0)μm
    ]

    p1s = [
        Point(900.0, -200.0)μm,
        Point(1100.0, -150.0)μm,
        Point(1100.0, -100.0)μm,
        Point(1100.0, 0.0)μm,
        Point(1100.0, 100.0)μm,
        Point(1100.0, 150.0)μm,
        Point(900.0, 200.0)μm
    ]
    reverse_paths && ((p0s, p1s) = (p1s, p0s))

    α0s = fill(reverse_paths ? 180.0° : 0.0°, length(p0s))
    α1s = copy(α0s)

    paths = [Path(p, α0=α0) for (p, α0) in zip(p0s, α0s)]
    tracks = reverse_channel ? reverse(eachindex(paths)) : eachindex(paths)
    styles = [Paths.Trace(2μm); fill(Paths.CPW(2μm, 2μm), length(paths))]

    rule = Paths.SingleChannelRouting(Paths.RouteChannel(channel), transition_rule, 50.0μm)
    setindex!.(Ref(rule.segment_tracks), tracks, paths)
    for (pa, p1, α1, sty) in zip(paths, p1s, α1s, styles)
        route!(pa, p1, α1, rule, Paths.CPW(2μm, 2μm))
    end
    return paths
end

@testset "Channels" begin
    ### Single-channel integration tests
    ## Geometry-level routing
    # StraightAnd90 only works with straight channel
    transition_rules = [
        Paths.StraightAnd90(min_bend_radius=25μm) # Can only be used with straight and trace if any paths enter from the sides, no curves or tapers
        Paths.BSplineRouting(endpoints_speed=150μm, auto_curvature=true)
    ]
    channel_segments = [
        Paths.Straight,
        Paths.Turn,
        Paths.BSpline,
        Paths.CompoundSegment
    ]
    channel_styles = [
        Paths.Trace(100μm),
        Paths.TaperTrace(100μm, 50μm)
    ]
    @testset "Straight" begin
        rule = transition_rules[1]
        paths = test_single_channel_reversals(rule, channel_segments[1], channel_styles[1])
        @test isempty(Intersect.intersections(paths...))
    end
    rule = transition_rules[2] # BSpline rule for all-angle transitions
    for segtype in channel_segments[2:end]
        @testset "$segtype channel" begin
            for sty in channel_styles
                test_single_channel_reversals(rule, segtype, sty)
            end
        end
    end
end