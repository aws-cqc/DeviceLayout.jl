# Schematics

## Schematic graphs

The schematic graph is a collection of logical information about the presence of components
and their connections. Its nodes are `ComponentNode`s, representing instances of `AbstractComponent`s
in the design. The edges are labeled with the names of the components' `Hook`s that are to
be fused together.

```@docs
SchematicDrivenLayout.SchematicGraph
SchematicDrivenLayout.ComponentNode
```

### Adding and connecting Components

```@docs
SchematicDrivenLayout.add_node!
SchematicDrivenLayout.fuse!
route!(::SchematicDrivenLayout.SchematicGraph,
    ::Paths.RouteRule,
    ::Pair{SchematicDrivenLayout.ComponentNode, Symbol},
    ::Pair{SchematicDrivenLayout.ComponentNode, Symbol},
    ::Any,
    ::Any)
SchematicDrivenLayout.RouteComponent
attach!(::SchematicDrivenLayout.SchematicGraph,
    ::S,
    ::Pair{T, Symbol},
    ::DeviceLayout.Coordinate
) where {S <: SchematicDrivenLayout.ComponentNode, T <: SchematicDrivenLayout.ComponentNode}
```

## Routing

A [`Paths.Route`](@ref) is like a `Path`, but defined implicitly in terms of its endpoints and rules (like "use only straight sections and 90 degree turns") for getting from one end to another. We can add `Route`s between components in a schematic using [`route!`](@ref), creating flexible connections that are only resolved after floorplanning has determined the positions of the components to be connected.

In more detail: Typically, each `fuse!` operation fully determines the position and rotation of the new node. The exception is that the first node added to each connected component of the `SchematicGraph` is positioned at the origin.

!!! info "Terminology note: connected component"
    
    There is a graph-theory term "connected component" unrelated to our `AbstractComponent`, indicating a subgraph whose nodes are all connected by edges and which isn't part of a larger such subgraph. For example, a fully connected graph has one connected component, the entire graph. Sometimes you may even hear these called "components", but below we use "connected component" for the graph-theory sense and "component" for `AbstractComponent`.

For example, a workflow might start by creating a node with a "chip template" component containing port [`hooks`](@ref SchematicDrivenLayout.hooks) and other boilerplate. We then `fuse!` any CPW launchers to the template. The devices in the middle of the chip are added and fused to one another without yet fixing their position relative to the chip template. Next, one connection is made between this connected component of devices and the connected component containing the template and launchers, fixing their relative positions. Since the chip template was added first, it will be centered at the origin.

At this point, further connections still need to be made between various device ports and CPW launchers positioned on the chip template, all of which are now fully constrained. Using `fuse!` to connect a `Path` to both ports would overconstrain the layout, causing floorplanning with `plan` to fail unless the `Path` is drawn precisely to agree with the existing constraints. But the designer may want to vary parameters that change the port positions without redefining that `Path`, or they may simply not want to have to calculate the precise path themselves. So the remaining connections are instead defined with the desired flexibility using [`route!`](@ref). This creates a `RouteNode` with edges to the `ComponentNode`s at its start and end points. Then, after `plan`, the initial floorplanning phase has determined the position of all fixed `Component`s, so the route node can find a path between its start and end points.

!!! tip "Schematic connections without geometric constraints"
    
    You can add edges to the schematic graph that will be ignored during `plan` using the keyword `plan_skips_edge=true` in `fuse!`.

### Differences between schematic and geometry-level routing

In geometry-level layout, we can extend a `Path` using `route!(path, p1, α1, rule, style; waypoints=[], waydirs=[])`. The schematic-level call looks a bit different: `route_node = route!(graph, rule, node1=>hook1, node2=>hook2, style, metadata; waypoints=[], waydirs=[], global_waypoints=false, kwargs...)`. In this case, the start and end points and directions are not known until after `plan`, and no path is actually calculated until until we `build!` or `render!` the schematic, or we call `path(route_node.component)`.

By default, `global_waypoints=false`, meaning that waypoints and directions are viewed as relative the the route start, with the positive x axis oriented along the route's initial start direction. Often `global_waypoints=true` is more useful, especially for a simple interactive routing workflow: When you view your final layout
built from the schematic, you may find that a route bends too sharply or goes too close to a
component. You can write down the points it needs to go to in the schematic's global coordinate system,
and add them as waypoints to the route. That is, if you go back to your layout script,
you can modify the `route!` call:

```julia
route_node = route!(
    g,
    rule,
    node1 => hook1,
    node2 => hook2,
    sty,
    meta; # Original route command
    # Add waypoint information to to `route!` call
    global_waypoints=true, # Waypoints are relative to global schematic coordsys
    # If global_waypoints=false (default), waypoints are relative to the route start
    # with the initial route direction as the +x axis
    waypoints=[Point(600.0μm, -3000.0μm)],
    waydirs=[90°]
)
```

Now the route in `route_node` is guaranteed to pass through the point (600.0μm, -3000.0μm)
on its way to its destination. If the `RouteRule`'s implementation uses `waydirs`, then it
will also have a direction of 90° at that point.

Channel routing at the schematic level also gets some special handling. When using
the [`Paths.SingleChannelRouting`](@ref) rule, the router will look for the rule's [`Paths.RouteChannel`](@ref)
in the schematic to get its global coordinates for routing. Additionally, paths are not assigned tracks in the rule using `Paths.set_track!` before `route!`. Instead, a route's track is set using the `track` keyword in `route!`,
defaulting to a new track at the bottom of the channel so far (`track=num_tracks(channel)+1`).
Because the routes are not drawn until later, the track offsets are still calculated using a
number of tracks given by the maximum track number of all routes that are eventually added to
the channel with the same rule. (Each route in the channel should still use the same instance of the `SingleChannelRouting` rule.)

Note that routes through a channel are no different from other routes as far as the schematic graph is concerned. That is, they are still just routes from one component's hook to another component's hook; they just happen to have a RouteRule that references the channel between them. One way to think about it is that the channel acts as a kind of extended waypoint. In particular, routes are not fused to the channel, and the channel component doesn't contain any individual route geometries in its own geometry (which is just empty).

## Schematics

```@docs
SchematicDrivenLayout.Schematic
SchematicDrivenLayout.plan
SchematicDrivenLayout.check!
SchematicDrivenLayout.build!
SchematicDrivenLayout.render!(::SchematicDrivenLayout.AbstractCoordinateSystem, ::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.LayoutTarget; kwargs...)
```

### Inspecting and manipulating schematics

Schematics allow you to produce layouts by specifying designs at a high level, in terms of
components and their connections. Often, this isn't quite enough to get the final artwork
you want. Maybe a wire needs to be routed differently, or a component needs to be modified
based on its position.

SchematicDrivenLayout allows you to inspect and modify a `Schematic` to make these sorts of
changes before `render!` renders it into polygons.

When you construct a `SchematicGraph`, you don't need to know exactly where a component will
end up. You can usually calculate it yourself, but there are some built-in utilities to
simplify things.

```@docs
SchematicDrivenLayout.indexof(::SchematicDrivenLayout.ComponentNode, ::SchematicDrivenLayout.SchematicGraph)
SchematicDrivenLayout.bounds(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.center(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.hooks(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.origin(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.transformation(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.find_components
SchematicDrivenLayout.find_nodes
```

If you have a `ComponentNode`, you can replace its component using an arbitrary function
that takes the original component as an argument:

```@docs
SchematicDrivenLayout.replace_component!
```

You can also replace it (or all components of that type) using a function that takes the
position in schematic-global or wafer-global coordinates as an argument:

```@docs
SchematicDrivenLayout.position_dependent_replace!
```

### Automatic crossover generation

You can automatically generate crossovers between `Path`s and `RouteComponent`s, including those nested within composite components. This is based on [`Path` intersection functionality](../paths.md#Intersections).

```@docs
SchematicDrivenLayout.crossovers!
```

### Checking schematics

It is often necessary to check that a planned `Schematic` obeys a set of constraints set
by the fabrication process. For instance, one may want to verify that all the junctions
in a floorplan are oriented in the right direction, e.g. pointing north. Instead of doing
this by eye, users should call `check!(sch::Schematic)`. This method can
run any number of checks provided by the user, but by default it only checks the global orientation of
[_checkable_](@ref SchematicDrivenLayout.check_rotation) components via the following methods:

```@docs
SchematicDrivenLayout.rotations_valid
```

To be able to `build!` or `render!` a floorplan (i.e. turn components into their geometries), users _must_
run `check!` first. Otherwise, these functions will throw an error.

## Visualization

SchematicDrivenLayout also contains some prototype schematic-visualization methods: if `GraphMakie` is present in the environment, then `GraphMakie.graphplot` can be used with a `SchematicGraph` to show nodes and edges or with `Schematic` to also place the components at their on-chip positions.
