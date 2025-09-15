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


######## Integration tests
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

    assign_channels!(ar) #, fixed_paths=Dict(2=>[2, 8, 4, 6]))
    assign_tracks!(ar)

    rule = Paths.StraightAnd90(min_bend_radius=0.1, max_bend_radius=0.1)
    # rule = Paths.StraightAnd45(min_bend_radius=0.1, max_bend_radius=0.1)
    # rule = Paths.BSplineRouting(endpoints_speed=7.5)
    # rts = make_routes!(ar, rule)
    # paths = [Path(rt, Paths.Trace(0.1)) for rt in rts]

    c = visualize_router_state(ar);

    save("autoroute_test.gds", c)
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

    assign_channels!(ar)
    assign_tracks!(ar)

    c = visualize_router_state(ar);

    save("autoroute_test.gds", c)
    return ar
end
