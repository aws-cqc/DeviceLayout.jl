# [API Reference](@id reference-index)

This section provides complete API documentation for DeviceLayout.jl.

## Module Overview

```
DeviceLayout                          # Core abstractions
├── Points, Polygons, Rectangles      # Basic geometry
├── CoordinateSystems                 # Native hierarchical geometry representation
├── Cells                             # Hierarchical geometry for GDSII
├── Paths                             # Path-based geometry
├── Intersect                         # Path intersections
├── Transformations                   # Coordinate transforms
├── Align                             # Bounding-box alignment transforms
├── GDS, DXF, Graphics                # File import/export backends
├── Texts, PolyText                   # Text elements
├── Autofill                          # Dummy fill for empty space
├── SimpleShapes                      # Simple geometry library
├── SolidModels                       # 3D geometry
└── SchematicDrivenLayout             # High-level design
```

## Reference Pages

All docstrings are on the [Full API Reference](@ref api-reference) page. Jump to a section:

### Core Geometry

- [Units](@ref api-units) — unit preferences and coordinate types
- [Points](@ref api-points) — `Point` type and coordinate access
- [AbstractGeometry](@ref api-abstractgeometry) — base geometry interface
- [GeometryEntity](@ref api-geometryentity) — concrete entities and rendering styles
- [GeometryStructure](@ref api-geometrystructure) — hierarchical structures and references
- [GeometryReference](@ref api-geometryreference) — structure and array references
- [Transformations](@ref api-transformations) — rotations, reflections, translations, alignment
- [Polygons](@ref api-polygons) — polygon types, rounding, and boolean clipping
- [Shapes](@ref api-shapes) — circles, ellipses, and shape primitives

### Paths and routes

- [Paths](@ref api-paths) — path construction, endpoints, directions
- [Path Manipulation](@ref api-path-manipulation) — `straight!`, `turn!`, `meander!`, `bspline!`, `attach!`
- [Path Styles](@ref api-path-styles) — `Trace`, `CPW`, `Taper`, `Strands`, `CompoundStyle`, `DecoratedStyle`
- [Routes](@ref api-routes) — automated path construction

### Layout

- [Coordinate Systems](@ref api-coordinate-systems) — semantic metadata layers, `place!`, cells, and GDS I/O
- [Texts](@ref api-texts) — text annotations and polytext rendering
- [Autofill](@ref api-autofill) — automatic pattern fill
- [Rendering](@ref api-rendering) — `render!` and curve discretization

### Schematic-Driven Layout

- [Components](@ref api-components) — `@compdef`, `@variant`, built-in and composite components
- [Hooks](@ref api-hooks) — `PointHook`, `HandedPointHook`, compass directions
- [Schematics](@ref api-schematics) — `SchematicGraph`, routing, `plan`, `check!`, `build!`
- [Technologies](@ref api-technologies) — `ProcessTechnology` and layer configuration
- [Targets](@ref api-targets) — `ArtworkTarget`, `SimulationTarget`, `SolidModelTarget`
- [PDKs](@ref api-pdks) — PDK generation utilities

### Solid Models

- [SolidModels](@ref api-solidmodels) — 3D geometry, physical groups, postrendering, and meshing
