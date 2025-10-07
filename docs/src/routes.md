# Routes

A [`Paths.Route`](@ref) implicitly defines a `Path` between two points, following a
[`Paths.RouteRule`](@ref), with a specified start and end direction. It's a building block
for "interactive autorouting". For simple cases, it lets you define a path between two
points without having to do any geometric calculations yourself. In more complicated cases,
you can provide additional waypoint constraints to guide it.

To draw a `Path` from a `Route`, you can use [`Path(r::Route, sty)`](@ref).

More often, you won't work directly with the `Route` type but will instead use [`route!`](@ref) to extend an existing path to an endpoint according to the rules you specify.

## Reference

```@docs
    Paths.Route
```

### Route rules

```@docs
    Paths.RouteRule
    Paths.BSplineRouting
    Paths.StraightAnd90
    Paths.StraightAnd45
    Paths.CompoundRouteRule
    Paths.SingleChannelRouting
    Paths.RouteChannel
```

### Route drawing

Calling `Path(r::Route, sty::Style)` creates a new `Path` at `p0(r)`, then extends it to
`p1(r)` using `route!`. The default implementation of `route!`, for a generic `RouteRule`,
first calls `reconcile!` to validate and modify waypoints as necessary. It then calls
`_route!` to draw the path, which by default calls `_route_leg!` to each waypoint in
order. (A "leg" is an informal abstraction describing the "unit" that the `RouteRule`
works with, which may be more than one `Paths.Segment`. For example, each leg in
`StraightAnd90` routing has a single 90-degree bend with up to one straight segment on
either side, or a single straight segment if no bend is necessary.)

```@docs
    Paths.Path(::Paths.Route, ::Paths.Style)
    Paths.route!
    Paths.reconcile!(::Paths.Path, ::Point, ::Any, ::Paths.RouteRule, ::Any, ::Any)
```

### Route inspection

A `Route` supports endpoint inspection much like a `Path` does:

```@docs
    Paths.p0(::Paths.Route)
    Paths.α0(::Paths.Route)
    Paths.p1(::Paths.Route)
    Paths.α1(::Paths.Route)
```

## Examples

### Channel routing

`RouteChannels` offer a way to run routes in parallel, with routes joining or leaving a channel at different points. Using `SingleChannelRouting`, we can set the "track" (a path offset from the channel centerline) for each route through the channel, as well as some rules for joining and leaving the channel from route start and end points. Here's a basic example with a straight channel:

```@example 1
using DeviceLayout, .PreferredUnits, FileIO
import DeviceLayout.Graphics: inch
# Define start and end points for various routes
p0s = [
    Point(100.0, -200.0)μm,  # Enter and exit from bottom
    Point(600.0, -150)μm,    # Enter from bottom, exit from right
    Point(-100.0, -100.0)μm, # Enter from lower left, exit from right
    Point(50.0, 150)μm,      # Enter from top, exit from right
    Point(100.0, 200.0)μm    # Enter and exit from top
]

p1s = [
    Point(400.0, -200.0)μm,
    Point(1100.0, -150.0)μm,
    Point(1200.0, 50.0)μm,
    Point(1100.0, 150.0)μm,
    Point(900.0, 200.0)μm
]

# Create channel
channel_path = Path()
straight!(channel_path, 1mm, Paths.Trace(0.1mm))
channel = Paths.RouteChannel(channel_path)
# Initialize paths
paths = [Path(p) for p in p0s]
# Define route rule 
transition_rule = Paths.StraightAnd90(25μm) # Manhattan with 25μm bend radius
margin = 50.0μm # Room for bends between endpoints and channel
rule = Paths.SingleChannelRouting(channel, transition_rule, margin)
# Set tracks
tracks = [1, 1, 2, 3, 4] # First two share a track
setindex!.(Ref(rule.segment_tracks), tracks, paths)
# Draw routes
for (pa, p1) in zip(paths, p1s)
    route!(pa, p1, 0.0°, rule, Paths.Trace(2μm))
end
c = Cell("test")
render!.(c, paths, GDSMeta())
render!(c, channel_path, GDSMeta(2))
save("straight_channel.svg", flatten(c); width=6inch, height=2inch)
```

```@raw html
<img src="../straight_channel.svg" style="width:6in;"/>
```

We can also have curved channels, like the `BSpline`-based example below. For the transition rule, `StraightAnd90` would no longer work for the paths that join the channel at an angle, so we use `BSplineRouting` instead. We also enable `auto_speed` and `auto_curvature` on that rule to help smooth out the B-splines and maintain continuous curvature.

```@example 1
# Create BSpline channel
channel_path = Path()
bspline!(
    channel_path,
    [Point(0.5, 0.5)mm, Point(1.0mm, 0.0μm)],
    0°,
    Paths.Trace(0.1mm),
    auto_speed=true,
    auto_curvature=true
)
channel = Paths.RouteChannel(channel_path)
# Initialize paths
paths = [Path(p) for p in p0s]
# Define route rule 
transition_rule = Paths.BSplineRouting(auto_speed=true, auto_curvature=true)
margin = 50.0μm
rule = Paths.SingleChannelRouting(channel, transition_rule, margin)
# Set tracks
tracks = [1, 1, 2, 3, 4] # First two share a track
setindex!.(Ref(rule.segment_tracks), tracks, paths)
# Draw routes
for (pa, p1) in zip(paths, p1s)
    route!(pa, p1, 0.0°, rule, Paths.Trace(2μm))
end
c = Cell("test")
render!.(c, paths, GDSMeta())
render!(c, channel_path, GDSMeta(2))
save("bspline_channel.svg", flatten(c); width=6inch, height=4inch)
```

```@raw html
<img src="../bspline_channel.svg" style="width:6in;"/>
```

Channels can also have variable width, like the example below using the `TaperTrace` style on a compound segment consisting of four turns.

```@example 1
# Create tapered, composite channel
channel_path = Path()
turn!(channel_path, 90°, 0.25mm, Paths.Trace(0.1mm))
turn!(channel_path, -90°, 0.25mm)
turn!(channel_path, -90°, 0.25mm)
turn!(channel_path, 90°, 0.25mm)
simplify!(channel_path)
setstyle!(channel_path[1], Paths.TaperTrace(0.1mm, 0.05mm))
channel = Paths.RouteChannel(channel_path)
# Initialize paths
paths = [Path(p) for p in p0s]
# Define route rule 
transition_rule = Paths.BSplineRouting(auto_speed=true, auto_curvature=true)
margin = 50.0μm
rule = Paths.SingleChannelRouting(channel, transition_rule, margin)
# Set tracks
tracks = [1, 1, 2, 3, 4] # First two share a track
setindex!.(Ref(rule.segment_tracks), tracks, paths)
# Draw routes
for (pa, p1) in zip(paths, p1s)
    route!(pa, p1, 0.0°, rule, Paths.Trace(2μm))
end
c = Cell("test")
render!.(c, paths, GDSMeta())
render!(c, channel_path, GDSMeta(2))
save("compound_channel.svg", flatten(c); width=6inch, height=4inch)
```

```@raw html
<img src="../compound_channel.svg" style="width:6in;"/>
```
