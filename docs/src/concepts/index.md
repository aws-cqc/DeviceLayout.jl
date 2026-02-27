# [Concepts](@id concepts-index)

This section explains the key concepts and design principles behind DeviceLayout.jl. Understanding these will help you use the package more effectively.

## Core Concepts

### [Geometry and Entities](@id geometry-concepts)

How DeviceLayout represents geometric objects and their metadata.

- [Entities and Metadata](entities.md) - Shapes, layers, and styles
- [Coordinate Systems](coordinate_systems.md) - Organizing geometry hierarchically
- [Transformations](transformations.md) - How transformations work

### [Paths and Rendering](@id paths-concepts)

Creating complex transmission line structures.

- [Path Architecture](paths.md) - Segments, styles, and rendering
- [The Render Pipeline](rendering.md) - How geometry becomes output

### [Schematic-Driven Design](@id schematic-concepts)

The high-level design paradigm.

- [Schematic-Driven Design](@ref schematic-driven-design) - The graph-based approach
- [Components and Hooks](components.md) - Building blocks and connections
- [PDK Architecture](pdk_architecture.md) - Technologies, targets, and layers

### [Simulation](@id simulation-concepts)

Preparing for electromagnetic analysis.

- [Solid Modeling](solid_modeling.md) - From 2D to 3D
- [Meshing](meshing.md) - Finite element mesh generation

## Choosing Your Approach

DeviceLayout supports multiple paradigms:

| Approach | Best For | Entry Point |
|----------|----------|-------------|
| **Low-level geometry** | Simple shapes, quick prototypes | `Rectangle()`, `Polygon()` |
| **Path-based** | Transmission lines, resonators | `Path()`, `straight!()` |
| **Schematic-driven** | Complex devices, team collaboration | `SchematicGraph()`, `fuse!()` |
| **PDK-based** | Production devices, reproducibility | Custom PDK package |

You can mix approaches—a schematic can contain both low-level geometry and path components.

## Design Philosophy

DeviceLayout is designed around these principles:

1. **Progressive complexity**: Start simple, add complexity as needed
2. **Composability**: Everything can be combined with everything else
3. **Semantic layers**: Design with meaning, map to fabrication later
4. **Reproducibility**: Designs should be fully parameterized and version-controlled
