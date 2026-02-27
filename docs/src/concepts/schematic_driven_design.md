# [Schematic-Driven Design](@id schematic-driven-design)

Schematic-driven design is DeviceLayout's high-level paradigm for building complex devices from reusable components. The core idea is that you describe your device as a graph of connected components, rather than manually position every element. The module `DeviceLayout.SchematicDrivenLayout` provides functionality for schematic-driven design.

The schematic-driven design flow goes like this:

  1. Define the [`Component`](@ref SchematicDrivenLayout.AbstractComponent) types that will appear in the device.
  2. Set parameters for the component instances that will appear in your device.
  3. Construct a [`SchematicGraph`](@ref SchematicDrivenLayout.SchematicGraph) by adding component instances (nodes) and specifying connections between them (edges), including special "route" components that define wires to be automatically routed after other components are placed.
  4. Construct a [`Schematic`](@ref SchematicDrivenLayout.Schematic) from the `SchematicGraph` by running an automated floorplanning routine that positions and orients components in a 2D layout.
  5. Check that the schematic follows high-level design rules—for example, that all Josephson junctions have the correct orientation for your fabrication process.
  6. Make any further changes now that components are placed, like creating crossovers between intersecting wires or filling the empty areas of the ground plane with holes for flux trapping.
  7. Render the schematic, generating 2D geometry for GDSII output or 3D geometry for finite-element simulation.

Here's what that looks like as a diagram, for comparison with [geometry-level flows](@ref dataflow-geometry):

```@raw html
<img src="../assets/schematic_dataflow.jpg"/>
```

## Key Concepts

### Components

Components are the building blocks—anything from a simple capacitor to a complex transmon qubit. Each component defines:

- **Parameters**: Configurable properties
- **Geometry**: What shapes it consists of
- **Hooks**: Where it can connect to other components

For more on Components, see [Concepts: Component](@id concept-components) and [Component API](@id api-components).

### Hooks

Hooks are connection points with both **position** and **direction**.

When two hooks are "fused," their positions coincide and directions oppose (like fishhooks pulling on each other). By convention, a components' hooks point inward, back towards the component.

Hooks can also have **handedness**: Fusing a left-handed hook to a right-handed hook will require a reflection in addition to rotation and translation to align the hooks.

### The Schematic Graph

A `SchematicGraph` is a graph where the nodes correspond to component instances and the edges correspond to connections between them (fused hooks).

Specifically, the metadata associated with a graph node is a `ComponentNode` containing an `id` and a `component`. A single `Component` may be placed in multiple nodes, but node will be assigned a unique `id` within the graph. That unique `id` is based on `name(component)` by default.

The metadata associated with a graph edge is the hook name for each fused node.

The first node added is the "root" and stays at the origin. All other positions will be calculated relative to it.

### Routing

A [`Paths.Route`](@ref) is like a `Path`, but defined implicitly in terms of its endpoints and rules (like "use only straight sections and 90 degree turns") for getting from one end to another. We can add a `RouteComponent` (wrapping a `Route`) between components in a schematic using [`route!`](@ref), creating flexible connections that are only resolved after floorplanning has determined the positions of the components to be connected.

See [Concepts: Routes](./routes.md) and the [Routing in Schematics](./routes.md#Routing-in-Schematics) section in particular.

### Planning

`plan(graph)` traverses the graph and computes positions, returning a `Schematic`:

1. Root component at origin
2. For each edge (connection), calculate child position
3. Continue until all standard components are positioned
4. Draw routes that depend on component positioning

!!! info "Terminology note: connected component"
    
    There is a graph-theory term "connected component" unrelated to `DeviceLayout.AbstractComponent`, indicating a subgraph whose nodes are all connected by edges and which isn't part of a larger such subgraph. For example, a fully connected graph has one connected component, the entire graph. Sometimes you may even hear these called "components", but we use "connected graph component" for the graph-theory sense and "component" for `AbstractComponent`.

If there are multiple connected graph components, the root (first node added) of each is positioned at the origin.

### Schematics

The `Schematic` object contains the `SchematicGraph` as well as the component positions computed by `plan`. It is itself an `AbstractCoordinateSystem`, and components are stored and positioned in a hierarchy of references in an internal coordinate system.

It is often necessary to check that a planned `Schematic` obeys a set of constraints. For instance, you may want to verify that all the junctions
in a floorplan are oriented in the right direction for your fabrication process. Instead of doing this by eye, users should call `check!(sch::Schematic)`. This method can
run any number of checks provided by the user, but by default it only checks the global orientation of components that implement the [SchematicDrivenLayout.check_rotation](@ref) method.

To be able to `build!` or `render!` a floorplan (i.e. turn components into their geometries), users _must_ run `check!` first. Otherwise, these functions will throw an error.

### Rendering (and Building)

Once you have your schematic, you can [`render!`](@ref (::SchematicDrivenLayout.AbstractCoordinateSystem, ::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.LayoutTarget; kwargs...)) it to a `Cell` using a `LayoutTarget` (for GDS files), or to a `SolidModel` with a `SolidModelTarget` (for 3D models). See also [Concepts: Rendering](@ref concept-rendering) and [Concepts: SolidModels](@ref concept-solidmodels).

[`build!`](@ref), an optional intermediate step between `plan` and `render!`, is useful for some workflows. `build!` instantiates all component geometries, replacing the `Component`s in the schematic's internal coordinate system with their corresponding `CoordinateSystem`s. This can help with debugging, for example, by separating the construction of native `CoordinateSystem` geometry and rendering that geometry to backend-specific primitives (`Polygon`s for `Cell`s or plane surfaces for `SolidModel`s).

## Example

```julia
# Define component connections
g = SchematicGraph("device")
qubit = add_node!(g, Transmon(...))
resonator = fuse!(g, qubit => :readout, Resonator(...) => :input)
feedline = fuse!(g, resonator => :output, Feedline(...) => :p0)

# Plan positions automatically
sch = plan(g)
check!(sch)
# Optional: Replace components with their geometry before rendering
# build!(sch)

# Render to output
render!(cell, sch, target)
```

## See Also

- [Components and Hooks](components.md)
- [PDK Architecture](pdk_architecture.md)
- [Tutorial: Schematic Basics](../tutorials/schematic_basics.md)
