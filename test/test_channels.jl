using Revise
using Graphs
using FileIO
import DeviceLayout.Paths: RouteChannel, ChannelRouter, assign_channels!, assign_tracks!, visualize_router_state

# @testset "Channels" begin    
    ### Unit tests

    ### Integration tests

# end
function test_single(transition_rule, channel_segment, channel_style; reverse_channel=false, reverse_paths=false)
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

    rule = Paths.SingleChannelRouting(Paths.RouteChannel(channel), transition_rule, 50.0μm)
    setindex!.(Ref(rule.segment_tracks), tracks, paths)
    for (track, pa, p1, α1) in zip(tracks, paths, p1s, α1s)
        route!(pa, p1, α1, rule, Paths.CPW(2μm, 2μm))
    end

    c = Cell("test", nm);
    render!.(c, paths, GDSMeta(), atol=1μm);
    render!(c, channel, GDSMeta(2));
    save("test.gds", c)
end
transition_rules = [
    Paths.BSplineRouting(auto_speed=true, auto_curvature=true)
    Paths.StraightAnd90(min_bend_radius=25μm) # Can only be used with straight and trace if any paths enter from the sides, no curves or tapers
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
