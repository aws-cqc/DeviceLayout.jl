# [Channel Autorouter](@id channel-autorouter-examples)

The channel autorouter connects pairs of pins by routing wires through a user-defined network of channels. Routing proceeds in two steps: **channel assignment** (choosing which channels each net's wire passes through) and **track assignment** (assigning non-overlapping tracks within each channel). See [Concepts: Channel Autorouter](./../concepts/channel_autorouter.md) for a conceptual overview.

The full code for these examples can be found [in `examples/ChannelAutorouter/ChannelAutorouter.jl` in the DeviceLayout.jl repository](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/examples/ChannelAutorouter/ChannelAutorouter.jl).

```@example autorouter
using DeviceLayout, FileIO
include("../../../examples/ChannelAutorouter/ChannelAutorouter.jl")
using .ChannelAutorouter
nothing # hide
```

## Simple

One horizontal channel, two pins, one net. The simplest possible autorouting scenario.

```@example autorouter
c, ar = ChannelAutorouter.example_simple()
save("autoroute_simple.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_simple.png"/>
```

## Parallel

Three nets routed left-to-right at matching heights through a grid of two vertical and three horizontal channels. No crossings needed.

```@example autorouter
c, ar = ChannelAutorouter.example_parallel()
save("autoroute_parallel.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_parallel.png"/>
```

## Crossing

Two nets that must cross in a shared vertical channel, forcing the router to assign multiple tracks.

```@example autorouter
c, ar = ChannelAutorouter.example_crossing()
save("autoroute_crossing.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_crossing.png"/>
```

There is also a variant of this example using the schematic routing interface.

## Fan-in / fan-out

Clustered pins on one side, spread-out pins on the other, routed through a single shared horizontal channel. The router assigns multiple tracks to accommodate the asymmetric spacing.

```@example autorouter
c, ar = ChannelAutorouter.example_fanin_fanout()
save("autoroute_fanin_fanout.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_fanin_fanout.png"/>
```

## Multichannel fan-out

Same topology as fan-in/fan-out, but with a dedicated horizontal channel per net. Each net uses exactly one track.

```@example autorouter
c, ar = ChannelAutorouter.example_multichannel_fanout()
save("autoroute_multichannel_fanout.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_multichannel_fanout.png"/>
```

## Grid

A 4×4 grid of horizontal and vertical channels with pins on different edges. Nets take multi-hop paths through the grid.

```@example autorouter
c, ar = ChannelAutorouter.example_grid()
save("autoroute_grid.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_grid.png"/>
```

## Angled channels

Non-Manhattan channels: two 45° diagonals crossing a horizontal channel. The router handles arbitrary channel geometry.

```@example autorouter
c, ar = ChannelAutorouter.example_angled()
save("autoroute_angled.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_angled.png"/>
```

## Dense

Six nets sharing just two horizontal and two vertical channels. Forces three tracks per channel.

```@example autorouter
c, ar = ChannelAutorouter.example_dense()
save("autoroute_dense.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_dense.png"/>
```

## B-spline channels

Curved channels using B-spline geometry with `BSplineRouting` transitions. Same fan-in/fan-out topology as above but with non-straight channels.

```@example autorouter
c, ar = ChannelAutorouter.example_bspline()
save("autoroute_bspline.png", c); nothing # hide
```

```@raw html
<img src="../autoroute_bspline.png"/>
```

## 100-net fan-out

100 nets fan out through a single wide channel from an inner row of pins to an outer row with twice the spacing.

```@example autorouter
c, ar = ChannelAutorouter.example_fanout100()
save("autoroute_fanout100.svg", c); nothing # hide
```

```@raw html
<img src="../autoroute_fanout40.svg"/>
```
