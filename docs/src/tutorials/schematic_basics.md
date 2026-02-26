# Tutorial: Schematic Basics

In [Working with Paths](working_with_paths.md), you built a resonator and feedline by manually positioning geometry. In this tutorial, you'll describe a similar device as a schematic — a graph of connected components — and let DeviceLayout handle placement.

## What You'll Learn

- Using a chip anchor to position components
- Connecting components with `fuse!`, `attach!`, and `route!`
- Automatic placement with `plan`
- Rendering with `ProcessTechnology` and `ArtworkTarget`

## Prerequisites

- Completed [Working with Paths](working_with_paths.md) tutorial
- Completed [Building a Component](building_a_component.md) tutorial

## Setup

```@example schematic
using DeviceLayout, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout
using FileIO
```

## Step 1: Create the path components

We'll build a resonator coupled to a feedline, with launchers at each end. Start by creating four paths. This is familiar from the Paths tutorial — we just need to create the paths without worrying about their relative positions.

A CPW style we'll use throughout:

```@example schematic
cpw = Paths.CPW(10μm, 6μm)
```

The feedline is a straight CPW section:

```@example schematic
feedline = Path(; name="feedline", metadata=SemanticMeta(:metal_negative))
straight!(feedline, 4mm, cpw)
```

A resonator with a shorted start and open termination:

```@example schematic
resonator = Path(; name="resonator", metadata=SemanticMeta(:metal_negative))
straight!(resonator, 200μm, cpw)
turn!(resonator, -90°, 50μm)
straight!(resonator, 300μm)
turn!(resonator, -90°, 50μm)
straight!(resonator, 500μm)
turn!(resonator, 180°, 50μm)
straight!(resonator, 500μm)
terminate!(resonator; initial=true, rounding=3μm, gap=0μm)
terminate!(resonator; rounding=5μm)
```

A launcher that we'll use twice — wirebonding pads that taper to the CPW trace width:

```@example schematic
launcher = Path(; name="launcher", metadata=SemanticMeta(:metal_negative))
launch!(launcher; trace1=cpw.trace, gap1=cpw.gap)
```

## Step 2: Create a chip anchor

In a schematic, `plan` positions components by traversing `fuse!` connections from a root node. Components connected only by `route!` must already be positioned — routes are resolved *after* placement.

This means we need an anchor to fix the positions of components that aren't directly chained together. A [`Spacer`](@ref) provides compass hooks at two points and has no geometry of its own:

```@example schematic
chip = Spacer(6mm, -2mm; name="chip")
for (hname, h) in pairs(hooks(chip))
    println("$hname: $(h.p), $(h.in_direction)")
end
```

The `p0_*` hooks are at the origin and the `p1_*` hooks are at (6mm, -2mm). We'll use them to position launchers at the chip edges.

## Step 3: Build the schematic graph

Create the graph and add the chip as the root node. The first node stays at the origin:

```@example schematic
g = SchematicGraph("resonator_feedline")
chip_node = add_node!(g, chip)
```

### Fuse launchers to the chip edges

We can use the same component in multiple nodes. Nodes always have unique IDs within the schematic graph; by default, these are generated based on the component name, but we can specify our own with `base_id`.

```@example schematic
launcher_in_node = add_node!(g, launcher; base_id="launcher_in")
launcher_out_node = add_node!(g, launcher; base_id="launcher_out")
```

[`fuse!`](@ref) creates rigid connections: it specifies that the second node will be positioned so that the two hooks coincide with opposite directions.

```@example schematic
fuse!(g, chip_node => :p0_west, launcher_in_node => :p0)
fuse!(g, chip_node => :p1_east, launcher_out_node => :p0)
```

The input launcher's pad is at the left edge (origin) with the path extending east. The output launcher's pad is at the right edge (6mm) — `fuse!` rotates it so its hook direction opposes `:p1_east`, which makes the launcher extend west.

### Chain the feedline from the input launcher

The feedline connects to the input launcher's narrow end:

```@example schematic
feedline_node = fuse!(g, launcher_in_node => :p1, feedline => :p0)
```

Notice that we did not call `add_node!` for `feedline` first. When given a bare component (not yet in the graph), `fuse!` adds the node automatically and returns it.

Paths are components in the schematic system. Every path has `:p0` (start) and `:p1` (end) hooks:

```@example schematic
h = hooks(feedline)
println("p0: $(h.p0.p), $(h.p0.in_direction)")
println("p1: $(h.p1.p), $(h.p1.in_direction)")
```

### Attach the resonator to the feedline

[`attach!`](@ref) connects a component to a specific point along a path, rather than to a named hook. This is a schematic-based analogue of how you used `attach!` in [Working with Paths](./working_with_paths.md) to place a reference to the resonator along the feedline.

Typically, you'd write something like `attach!(g, feedline_node, resonator_node => :feedline, 2mm, location=1)` to position a resonator's `:feedline` hook 2mm along and on the right side of the path. However, we made a choice to work with bare Paths as lightweight components, and the bare Path doesn't have such a hook at the necessary position and orientation.

Instead, place a resonator at a coupling position on the feedline using a Spacer:

```@example schematic
resonator_node = add_node!(g, resonator)
# This won't attach with the desired spacing and orientation
# attach!(g, feedline_node, resonator_node => :p0, 2mm, location=1)
# So we'll attach another Spacer
coupling_gap = 5μm
spacing = coupling_gap + Paths.extent(cpw)
coupling_spacer_node = attach!(g, feedline_node, Spacer(0μm, -spacing) => :p0_south, 2mm; location=1)
fuse!(g, coupling_spacer_node => :p1_west, resonator_node => :p0)
```

In practice, you'll usually avoid needing the `Spacer` by defining your own resonator component with the necessary hook. However, it may be a useful exercise to think through how this Spacer results in the desired resonator position.

The `location=1` offsets the attachment to the right side of the feedline trace, as though with a feedline hook pointing back towards the trace ("north"). The `:p0_south` hook on the spacer points opposite that hook already, so `attach!` does not rotate it. The resonator then fuses to the `:p1_west` hook, by orienting its `:p0` hook in the opposite direction ("east"). Since the `:p0` hook points along a path's initial direction, the initial direction of the resonator path is "east". 

Meanwhile, thanks to the Spacer, the path starts at a point `spacing` below the edge of the ground of the feedline CPW; since `spacing = coupling_gap + Paths.extent(cpw)`, the width of the ground plane between the feedline and resonator is `coupling_gap`.

### Route the feedline to the output launcher

The feedline end and the output launcher's narrow end are both positioned, but they don't coincide — there's a gap between them. [`route!`](@ref) creates a flexible path that will be computed after placement:

```@example schematic
route_node = route!(g, Paths.StraightAnd90(50μm),
    feedline_node => :p1, launcher_out_node => :p1,
    cpw, SemanticMeta(:metal_negative))
nothing # hide
```

[`Paths.StraightAnd90`](@ref) routes using straight segments and 90° bends with a minimum bend radius of 50μm.

## Step 4: Plan and render

`plan` traverses the `fuse!` connections to position components, then resolves routes between the now-positioned endpoints:

```@example schematic
sch = plan(g; log_dir=nothing)
```

To see that our components are now positioned, we can get geometric information based on the schematic and a node of our choice:

```@example schematic
println("Resonator bounds: Rectangle($(bounds(sch, resonator_node).ll), $(bounds(sch, resonator_node).ur))")
println("Resonator center: $(center(sch, resonator_node))")
println("Resonator origin: $(origin(sch, resonator_node))")
println("Resonator global transformation: $(transformation(sch, resonator_node))")
println("Resonator p1 hook: $(hooks(sch, resonator_node).p1)")
```

Our route now has endpoints, and we can construct its path:

```@example schematic
routed_path = SchematicDrivenLayout.path(component(route_node))
println("Route length: $(pathlength(routed_path))")
```

`check!` validates design rules (component orientations, etc.) and must be called before rendering:

```@example schematic
check!(sch) # No relevant design rules here
```

To render the schematic to GDS, we need a target that maps semantic layer names to GDS layers. In the [First Layout](first_layout.md) tutorial, you did this manually with a `Dict`. [`ArtworkTarget`](@ref) wraps a [`ProcessTechnology`](@ref) to handle it automatically:

```@example schematic
tech = ProcessTechnology(
    (; metal_negative=GDSMeta(0)),
    (;)
)
target = ArtworkTarget(tech)
```

The first argument to `ProcessTechnology` is a `NamedTuple` mapping semantic layer symbols to `GDSMeta`. The second is process parameters (empty here).

Render and save:

```@example schematic
cell = Cell("resonator_feedline", nm)
render!(cell, sch, target)

save("resonator_feedline.gds", cell)
save("resonator_feedline.svg", cell);
nothing # hide
```

```@raw html
<img src="resonator_feedline.svg" style="width: 5in;"/>
```

## Summary

In this tutorial, you learned:

- **`Spacer`**: An anchor component with compass hooks for positioning other components at fixed locations
- **`fuse!`**: Rigid connections that position components during planning — hooks coincide with opposite directions
- **`attach!`**: Connects a component to a specific point along a path
- **`route!`**: Flexible connections resolved after placement — endpoints must already be positioned by `fuse!`
- **`plan`**: Traverses `fuse!` edges to compute positions, then resolves routes
- **`check!`**: Validates design rules (required before rendering)
- **`ProcessTechnology` and `ArtworkTarget`**: Structured mapping from semantic layers to GDS layers

## Next Steps

Continue to [Creating a PDK](creating_a_pdk.md) to learn how to package components, technologies, and targets for team use.

## See Also

- [Schematic-Driven Design Concepts](@ref schematic-driven-design) for how planning and hook fusion work
- [QPU17 Example](../examples/qpu17.md) for a full-scale schematic design
- [Routing Strategies](../how_to/schematics/routing_strategies.md) for different `RouteRule` options
