# Channel Autorouter

The channel autorouter connects pairs of pins by choosing paths through a user-defined
network of [`Paths.RouteChannel`](@ref)s. It is the multi-net, multi-channel
counterpart to the [`Paths.SingleChannelRouting`](@ref) rule described in
[Routes](./routes.md#Channel-routing): rather than having the user assign each route a
channel and a track by hand, the autorouter decides which channels each wire passes
through and which track it occupies within each channel.

!!! warning

    Autorouting solutions may change between minor DeviceLayout.jl versions. Only breaking
    changes to the autorouter API, not its output, will force major version bumps.
    Autorouting is under active development, so upcoming minor versions are especially
    likely to see changes in solutions for fixed routing problems.

## Problem setup

A channel-routing problem is described by three pieces of data:

  - **Channels**: a list of [`Paths.RouteChannel`](@ref)s. Channels can be straight,
    curved, tapered, or composite — any `Path` that is valid as a `RouteChannel` is
    valid as an autorouter channel. Channels intersect where their centerlines cross;
    the autorouter precomputes these intersections and treats them as the graph along
    which wires may travel.
  - **Pins**: a list of `PointHook`s giving the location and direction of
    each pin. A pin's ray along its direction must hit a channel; the first
    channel it hits becomes the pin's entry or exit channel.
  - **Nets**: pairs `(i, j)` of pin indices that should be connected.

The autorouter then attempts to connect each net by routing a wire from its source
pin, through a sequence of channels, to its destination pin.

## How routing works

Routing happens in two stages:

 1. **Channel assignment** picks, for each net, the sequence of channels its wire will
    traverse. This is a shortest-path search in a graph whose vertices are channels and
    pins and whose edges are channel intersections, weighted by physical distance
    between successive intersections along each channel. Nets are processed one at a
    time. Channel assignment does **not** currently take into account crossings,
    congestion, or channel capacity. 
 2. **Track assignment** proceeds channel by channel. Within a channel, every wire
    segment occupies an interval of arclength between its entry and exit. Segments
    whose intervals overlap must be placed on distinct tracks. The autorouter builds a
    vertical-constraint graph (which segment must be "above" which, given the crossings
    that occur entering or leaving the channel at the interval endpoints) and picks a
    feasible track order that uses as few tracks as possible, merging non-overlapping
    segments onto shared tracks when compatible.

The algorithms follow the classical channel-routing literature (Hashimoto & Stevens;
Yoshimura & Kuh), with a crossing-aware variant due to Condrat, Kalla, & Blair to
handle channels shared by nets with avoidable crossings. See [References](#References) below.

Once channels and tracks have been assigned, the autorouter builds a
[`Paths.Route`](@ref) for each net. The
`Route`'s rule is a `Paths.AutoChannelRouting` that uses a user-supplied
**transition rule** (for the short legs between pins and channels, and between
adjacent channels) and a **margin** (how much room to leave for bends at each
transition). The transition rule is typically [`Paths.StraightAnd90`](@ref),
[`Paths.StraightAnd45`](@ref), or [`Paths.BSplineRouting`](@ref).

## Geometry-level usage

At the geometry level, construct a `Paths.ChannelRouter` from nets, pins, and
channels, then call `Paths.autoroute!`:

```julia
using DeviceLayout, .PreferredUnits
import DeviceLayout.Paths:
    ChannelRouter, RouteChannel, autoroute!, visualize_router_state

# Two horizontal channels and one vertical channel, with crossed nets
channels = RouteChannel.([
    (p = Path(5.0, -1.0; α0 = 90°); straight!(p, 8.0, Paths.Trace(2.0)); p),
    (p = Path(-1.0, 0.0);           straight!(p, 10.0, Paths.Trace(2.0)); p),
    (p = Path(-1.0, 6.0);           straight!(p, 10.0, Paths.Trace(2.0)); p)
])

hooks = [
    PointHook(Point(2.0, -0.5), 270°),   # below h_bot
    PointHook(Point(8.0, -0.5), 270°),   # below h_bot
    PointHook(Point(2.0,  6.5),  90°),   # above h_top
    PointHook(Point(8.0,  6.5),  90°)    # above h_top
]
nets = [(1, 4), (2, 3)]  # crossed

ar     = ChannelRouter(nets, hooks, channels)
routes = autoroute!(ar, Paths.StraightAnd90(0.1), 0.1)  # transition rule, margin

c = visualize_router_state(ar; wire_width = 0.05)
```

The returned `routes` are [`Paths.Route`](@ref) values; convert any of them to a drawn
path with `Path(route, style)`. `visualize_router_state` returns a `Cell` that overlays
the channels, tracks, pin labels, and route geometry — useful for debugging an
unexpected assignment. To check whether every route actually reaches its destination,
call `Paths.validate_routes`.

Worked examples for common topologies (parallel, crossing, fan-in/fan-out, grid,
angled, B-spline, dense, many-net fan-out) live in the
[Channel Autorouter examples page](@ref channel-autorouter-examples).

## Schematic-level usage

At the schematic level, the autorouter is exposed as a [`Paths.RouteRule`](@ref):
construct a `Paths.AutoChannelRouting` from a `ChannelRouter` (or directly from a
vector of channels) and use it as the rule in
[`route!`](@ref route!(::SchematicDrivenLayout.SchematicGraph, ::Paths.RouteRule, ::Pair{SchematicDrivenLayout.ComponentNode, Symbol}, ::Pair{SchematicDrivenLayout.ComponentNode, Symbol}, ::Any, ::Any)).
Every route that shares a channel set should use the **same** rule instance, so that
the underlying router sees all nets:

```julia
ar   = ChannelRouter(channels)
rule = Paths.AutoChannelRouting(ar, Paths.StraightAnd90(0.1mm), 0.1mm)

route!(g, rule, node1 => :port_a, node2 => :port_b, Paths.Trace(5μm), meta)
route!(g, rule, node3 => :port_a, node4 => :port_b, Paths.Trace(5μm), meta)

sch = plan(g)
```

Pin positions and directions are pulled from the component hooks at each route's
endpoints during `plan`, and channel assignment + track assignment run once these have
been set for the last route that uses `rule`. Schematic-level autorouting does not allow the user to
pre-assign tracks—while [`Paths.SingleChannelRouting`](@ref) uses the `track` keyword in `route!`
(defaulting to incrementing by 1 for each new route), `AutoChannelRouting` makes all
track assignments automatically during `plan`.

Unlike with `SingleChannelRouting`, the autorouter does not look for channels in the
schematic to find their global coordinates. Channels must be provided to the autorouter in global coordinates. Channels may still be added to a schematic, but this has no effect on routing.

## Limitations

  - A pin's outward ray must hit exactly one channel. If no channel is in the ray's
    path, or the pin points the wrong way, graph construction fails.
  - Channels are assumed not to self-intersect; self-intersections are ignored with an
    `@info` message.
  - Two channels may intersect at most once. Re-entering the same channel pair is not
    supported.
  - Every net in a single `AutoChannelRouting` rule must start at a distinct pin. Nets
    that share a source pin should be split into separate rules (or merged upstream).
  - Track assignment does not care about proximity of slightly misaligned tracks
    entering from different channels or pins; only exact alignment of entry/exit segments
    and topologically avoidable crossings constrain track assignment.

## References

  - Hashimoto & Stevens, ["Wire routing by optimizing channel assignment within large apertures"](https://cs.baylor.edu/~maurer/CSI5346/originalCR.pdf), *DAC '71: Proceedings of the 8th Design Automation Workshop* (1971).
  - Yoshimura & Kuh, ["Efficient Algorithms for Channel Routing"](https://my.ece.utah.edu/~kalla/phy_des/yk.pdf), *IEEE Transactions on Computer-Aided Design of Integrated Circuits and Systems* (1982).
  - Condrat, Kalla, & Blair, ["Crossing-aware Channel Routing for Photonic Waveguides"](https://my.ece.utah.edu/~kalla/papers/condrat_crossing-aware_channel_routing_for_photonic_waveguides.pdf), 2013 IEEE 56th International Midwest Symposium on Circuits and Systems (MWSCAS) (2013).
