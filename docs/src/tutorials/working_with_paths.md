# Tutorial: Working with Paths

Paths are one of the most powerful features of DeviceLayout.jl, allowing you to create complex transmission lines and other path-based structures. In this tutorial, you'll create a layout for a quarter-wave coplanar-waveguide resonator.

## What You'll Learn

- Creating and manipulating paths
- Adding straight segments and turns
- Using path styles
- Creating tapers between different styles
- Attaching structures along paths
- Using periodic styles and overlays
- Adding launchers and terminations
- Splitting and splicing paths

## Prerequisites

- [Getting Started](getting_started.md): Installing Julia and setting up your development environment
- [First Layout](first_layout.md): Learning the basics of creating geometries

## Setup

```@example paths
using DeviceLayout, DeviceLayout.PreferredUnits
using FileIO
```

## Step 1: Creating the resonator path

A path is an ordered collection of segments, each with a style that determines how it's rendered. We'll
start with a straight coplanar waveguide section. This will be the shorted end of our resonator,
which will eventually be coupled to a measurement line.

```@example paths
# Create a path starting at the origin, pointing along the x axis
resonator_path = Path(Point(0nm, 0nm), α0=0°; name="resonator", metadata=SemanticMeta(:metal_negative))
# Origin and x axis are defaults, so `resonator_path = Path(; ...)` does the same thing

# Start with a straight segment at the top that will couple to a measurement line
# Add a straight segment with a simple CPW style (10μm trace with 6μm gap)
coupling_length = 200μm
resonator_style = Paths.CPW(10μm, 6μm)
straight!(resonator_path, coupling_length, resonator_style)
# Place in a CoordinateSystem
preview_cs = CoordinateSystem("preview")
place!(preview_cs, resonator_path)
preview_cs
```

The start of the path is effectively shorted to ground already, but we can add rounding to a short
with [`terminate!`](@ref):

```@example paths
# This is already shorted, but let's add rounding to the short
terminate!(resonator_path; initial=true, rounding=3μm, gap=0μm) # 0μm gap => short
preview_cs # still holds the reference to `resonator_path`, don't need to re-add it
```

We want to meander the path to reach a certain total length, so let's keep adding segments:

```@example paths
# Hanger geometry to get away from coupling region
# 90° clockwise turn with 50μm radius
bend_radius = 50μm
hanger_length = 200μm
turn!(resonator_path, -90°, bend_radius) # continues with same style
straight!(resonator_path, hanger_length)
turn!(resonator_path, -90°, bend_radius) # continues with same style

# Meander to target length
# Calculate number of turns
target_length = 4mm
remaining_length = target_length - pathlength(resonator_path)
straight_length = 200μm
turn_radius = 50μm
section_length = straight_length + pi*turn_radius
remaining_full_sections = Int(floor(remaining_length/section_length))
# Create meander
sgn = 1
for i in 1:remaining_full_sections
    straight!(resonator_path, 200μm)
    turn!(resonator_path, sgn*180°, 50μm)
    sgn = -sgn
end
# Finish path
straight!(resonator_path, target_length - pathlength(resonator_path))
terminate!(resonator_path; rounding=5μm) # Open termination with gap = CPW gap
preview_cs
```

## Step 2: Creating the measurement feedline

We'll create a "CPW launcher" structure,
with a wide pad where the external signal line is wirebonded to the CPW trace,
tapering to a narrower style.

```@example paths
pad_style = Paths.CPW(300μm, 150μm)
narrow_style = Paths.CPW(10μm, 6μm)
feedline = Path(; name="feedline", metadata=SemanticMeta(:metal_negative))
# Straight, wide CPW
straight!(feedline, 250μm, pad_style)
# Explicitly taper to `narrow_style`
straight!(feedline, 250μm, Paths.TaperCPW(pad_style, narrow_style))
# Add open termination gap at the start
terminate!(feedline; initial=true)
# New CoordinateSystem to preview geometry
preview_feedline_cs = CoordinateSystem("preview_feedline")
place!(preview_feedline_cs, feedline)
preview_feedline_cs
```

Continue the path and do the reverse at the other end:

```@example paths
straight!(feedline, 2mm, narrow_style)
straight!(feedline, 250μm, Paths.Taper()) # Automatic taper
straight!(feedline, 250μm, pad_style)
terminate!(feedline)
preview_feedline_cs
```

This time, we used a generic `Taper()` style, which will automatically be resolved to the correct `TaperCPW` based on its neighbors.

The `(segment, style)` pairs are the path's "nodes":

```@example paths
Paths.nodes(feedline)
```

Some operations require specifying which node to operate on. We can combine nodes with [`simplify!`](@ref), which is useful for abstracting away unnecessary details and for identifying the correct section of a path more easily. For now, combine each launcher into a single node:

```@example paths
simplify!(feedline, 5:7)
simplify!(feedline, 1:3)
Paths.nodes(feedline)
```

The [`launch!`](@ref) method is a convenience function for creating a taper, pad, and open termination, then simplifying.

## Step 3: Attaching bridges to the feedline

Let's start by defining a geometry for a basic "staple" bridge or crossover tying the ground
planes on either side of a CPW together:

```@example paths
bridge_cs = CoordinateSystem("bridge")
place!(bridge_cs, centered(Rectangle(10μm, 40μm)), :bridge) # metal
place!(bridge_cs, centered(Rectangle(16μm, 30μm)), :bridge_base) # scaffold
```

To attach bridges to the feedline, we'll create a periodic style that attaches a bridge every 100μm with [`Paths.PeriodicStyle`](@ref), then overlay it on the feedline with [`overlay`](@ref).

```@example paths
# Temporary path to define periodic style
template_path = Path()
straight!(template_path, 100μm, Paths.NoRender()) # Extend template for one period
attach!(template_path, sref(bridge_cs), 50μm) # Attach in the middle of period
bridge_sty = Paths.PeriodicStyle(template_path) # Style repeating every 100μm
# Overlay this on the feedline
overlay!(feedline, bridge_sty, DeviceLayout.NORENDER_META, i=2)
# Also valid:
# attach!(feedline, sref(bridge_cs), (0.05mm:0.1mm:pathlength(feedline[2])), i=2)
preview_feedline_cs
```

## Step 4: Removing unwanted bridges

We want to attach the resonator to the feedline, but before we do that, we should make sure it won't collide with any bridges.

To avoid collisions, split the feedline into three segments using the [`split`](@ref) and [`splice!`](@ref) idiom, then override the style of the coupling section with `setstyle!`:

```@example paths
# Split node 2 at the ends of the coupling segment
# Then splice the resulting 3 nodes back in place of node 2
splice!(feedline, 2, split(feedline[2], [1mm, 1mm + coupling_length]))
Paths.setstyle!(feedline[3], narrow_style) # Back to style without bridges
Paths.nodes(feedline)
```

# Step 5: Attaching bridges to the resonator

Simplify the resonator path, then attach bridges to the simplified segment:

```@example paths
simplify!(resonator_path, 4:lastindex(resonator_path)) # from the hanger to the end
overlay!(resonator_path, bridge_sty, DeviceLayout.NORENDER_META; i=lastindex(resonator_path))
# Also valid:
# attach!(resonator_path, sref(bridge_cs), (0.05mm:0.1mm:pathlength(resonator_path[end])))
preview_cs
```

# Step 6: Attaching the resonator to the feedline

Use [`attach!`](@ref) to place a reference to the resonator along the feedline:

```@example paths
ground_strip_width = 5μm
res_extent = Paths.extent(resonator_path[1].sty)
origin_offset = Point(0μm, -ground_strip_width - res_extent) # from bottom edge of feedline
# Attach to the feedline
# to the 3rd segment (i=3)
# on the bottom edge (location=1)
# 0mm into the segment
attach!(feedline, sref(resonator_path, origin_offset), 0mm; i=3, location=1)
save("resonator.gds", Cell(preview_feedline_cs)) # save with arbitrary layer mapping
preview_feedline_cs
```

And there's your resonator!

## Summary

In this tutorial, you learned:

- **Path creation**: `Path()` with optional start point, angle, name, and metadata
- **Segments and styles**: Paths are a sequence of segment/style pairs ("nodes")
- **Path extension**: `straight!()` and `turn!()` to build paths
- **CPWs**: `Paths.CPW` and `Paths.TaperCPW` for coplanar waveguides
- **Terminations**: `terminate!()` for open and short endings
- **Attachments**: `attach!()` for placing structures along paths
- **Periodic styles**: `Paths.PeriodicStyle` for repeating styles
- **Overlays**: `overlay!` for drawing additional styles over a path
- **Simplification**: `simplify!` to combine path nodes
- **Splitting**: `split` to split path nodes
- **Splicing**: `splice!` to replace part of a path with new nodes

## Next Steps

Continue to [Building a Component](building_a_component.md) to learn how to encapsulate your layouts into reusable, parameterized components.

## See Also

- [Paths Concept](@ref paths-and-styles) for deeper understanding
- [Paths Reference](@ref) for complete API
- [How to Create a CPW](@ref) for specific recipes
