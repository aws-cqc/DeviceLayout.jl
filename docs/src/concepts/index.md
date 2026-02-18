# [Concepts](@id concepts-index)

This section explains the key concepts behind DeviceLayout.jl. Understanding these will help you use the package more effectively.

### [Geometry](@id geometry-concepts)

How DeviceLayout handles geometric objects and their metadata.

- [Units](units.md): Lengths, angles, and unit preferences
- [Points](points.md): Basics of 2D points
- [Geometry](geometry.md): Overview of geometry-level abstractions and layout workflow
- [Transformations](transformations.md): Coordinate transformations
- [Polygons](polygons.md): Polygons and polygon clipping (geometric Booleans)
- [Coordinate Systems](coordinate_systems.md): Hierarchical geometry with metadata
- [Texts](texts.md): Text elements as geometric entities
- [Paths](paths.md): Transmission lines and other path-based geometry
- [Routes](routes.md): Defining Paths implicitly based on routing rules
- [Rendering and File Export](render.md): How geometry becomes output data
- [Solid Models](solidmodels.md): 3D geometry and meshing

### [Schematic-Driven Design](@id schematic-concepts)

The high-level design paradigm.

- [Schematic-Driven Design](@ref schematic-driven-design): The graph-based approach
- [Components](components.md): Building blocks and connections
- [Autofill](autofill.md): Filling empty space with repeating patterns
- [PDKs](pdks.md): Process design kits for organizing and sharing components
- [Style Guide](styleguide.md): Conventions for predictable, maintainable components
