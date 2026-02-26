# Geometry

DeviceLayout.jl lets you define 2D shapes, place shapes in structures, and place references to structures inside other structures. We call this workflow "geometry-level layout", the most basic way of interacting with DeviceLayout.jl. This page explains the main abstract types used for geometry representation, the ideas behind rendering 3D models with DeviceLayout.jl, and the standard flow of geometry-level layout.

## Geometry representation

Within the DeviceLayout.jl type hierarchy, ["shapes" are `GeometryEntity` subtypes](./geometry.md#Entities) like `Polygon` and `Rectangle`.

["Structures" are `GeometryStructure` subtypes](./geometry.md#Structures) like `Cell`, `CoordinateSystem`, `Path`, and `Component`. A structure can contain many entities (its "elements"), and it associates each entity with its own piece of metadata (generally specifying the "layer" that entity belongs to).

Structures may also contain [references to other structures](./geometry.md#References). The most common `GeometryReference` subtype, `StructureReference`, wraps a structure together with a coordinate transformation that specifies its relative positioning and orientation within the containing structure.

Here's a type hierarchy with the most important types for geometry representation:

```
AbstractGeometry{S<:Coordinate}
    ├── GeometryEntity (basic "shapes")
    │   ├── Polygon, Rectangle, Text, Ellipse...
    │   ├── ClippedPolygon (result of polygon [clipping](./polgyons.md#Clipping) — `union2d`, etc.)
    │   ├── Paths.Node (one segment+style pair in a Path)
    │   └── StyledEntity (entity + rounding or other rendering customization)
    ├── GeometryStructure (can contain entities & references)
    │   ├── Path (specialized for curved traces)
    │   ├── AbstractComponent (parameterized geometry)
    │   └── AbstractCoordinateSystem (container for entities and references)
    │       ├── CoordinateSystem (for low-level geometry)
    │       ├── Cell (for GDS output)
    │       └── Schematic (for high-level device design)
    └── GeometryReference
        ├── StructureReference
        └── ArrayReference
```

Note that `Point{T} <: StaticArrays.FieldVector{2,T}` is not an `AbstractGeometry` subtype (see [Points](./points.md)).

### [AbstractGeometry](@id concept-abstractgeometry)

An `AbstractGeometry{T}` subtype will use the coordinate type `T` for its geometry data. It have a bounding box and associated methods (`bounds`, `lowerleft`, `upperright`, `center`). It will also support the [transformation interface](./transformations.md), including the alignment interface. The important subtypes are `GeometryEntity`, `GeometryStructure`, and `GeometryReference`.

See [API Reference: AbstractGeometry](@ref api-abstractgeometry).

### [Entities](@id concept-geometryentity)

Entities are "simple" geometric elements. Entity subtypes include [`AbstractPolygon`](./polygons.md) (`Polygon` and `Rectangle`) and the individual pieces ("nodes") of a [`Path`](./paths.md).

An entity can be associated with a single piece of metadata. Entities can comprise multiple disjoint shapes, as in a `Paths.Node` with a CPW style, or a `ClippedPolygon` representing the union of disjoint polygons. Even in that case, all shapes in an entity must be in the same layer.

In addition to the `AbstractGeometry` interface (bounds and transformations), a `GeometryEntity` implements `to_polygons`, returning a `Polygon` or vector of `Polygon`s.

See [API Reference: Entities](@ref api-geometryentity).

#### Entity Styles

Entities can also be "styled" by pairing them with a [`GeometryEntityStyle`](@ref api-entitystyle). This creates a `StyledEntity <: GeometryEntity` that still supports the entity interface (including the ability to be styled). Generic entity styles are used to supply additional rendering directives specific to one entity, like tolerance, mesh sizing, and toggles for rendering based on global rendering options. `Polygons` have the special [`Rounded`](@ref) style, and `ClippedPolygons` can have a [`StyleDict`](@ref) applying different styles to different contours.

### [Structures](@id concept-geometrystructure)

Structures are "composite" geometric objects, containing any number of `GeometryEntity` elements and their metadata, accessed with the `elements` and `element_metadata` methods. They can also contain references to other structures, accessed with `refs`. Structures also have a `name` and can be `flatten`ed into an equivalent single structure without references. Metadata can be recursively changed in-place with `map_metadata!` or in a copy with `map_metadata`. The type parameter of a `GeometryStructure` determines the coordinate type of its elements.

See [API Reference: Structures](@ref api-geometrystructure).

#### Unique Names

It's generally desirable to give unique names to distinct structures. In particular, the GDSII format references cells by name, leading to errors or undefined behavior if different cells have the same name. The `uniquename` function makes it possible to ensure unique names on a per-Julia-session basis or until `reset_uniquename!` resets the name counter. Structures that are not constructed directly by the user will generally have names generated by `uniquename`. `GDSWriterOptions` also provides a `rename_duplicates` option to automatically use unique names when saving a `Cell` to GDS.

#### Metadata

The layer of an element in a structure is stored as a `DeviceLayout.Meta` object ("element metadata"). `GDSMeta` stores integer values for layer and datatype, while `SemanticMeta` stores a layer name as a `Symbol` as well as integer values for `level` and `index`.

### [References](@id concept-geometryreference)

The main `GeometryReference` subtype is `StructureReference`, which points to a structure together with a transformation that positions it relative to the structure holding the reference. An `ArrayReference` also contains parameters specifying a 2d grid of instantiations of the referenced structure. The methods [`sref`](@ref) and [`aref`](@ref) are convenient for creating `StructureReference`s and `ArrayReference`s, respectively. The transformation and structure can be accessed with the `transformation` and `structure` methods.

If a structure `s` contains a reference `r` somewhere in its reference hierarchy,
we can use `transformation(s, r)` to find the total transformation of that
reference relative to the top-level structure.

As with structures, a reference can also be `flatten`ed into a structure with all elements at the top level and no references.

For convenience, you can get referenced structures by indexing their parent with the structure name, as in `cs["referenced_cs"]["deeper_cs"]`.

See [API Reference: References](@ref api-geometryreference).

## Solid Models

We can also render structures to a [3D model](./solidmodels.md). DeviceLayout.jl uses [Open CASCADE Technology](https://dev.opencascade.org/), an open-source 3D geometry library, through the API provided by [Gmsh](https://www.gmsh.info/doc/texinfo/gmsh.html), a 3D finite element mesh generator.

Even though our geometry is purely 2D, we can generate a `SolidModel` by providing a map from layer name to position in the third dimension (`zmap`) as well as a list of Booleans, extrusions, and other operations to perform after rendering the 2D entities (`postrender_ops`).

It's not really recommended to do this directly from geometry-level layout. There are tools in the schematic-driven layout interface that handle some of the complexity for you (see [`SchematicDrivenLayout.SolidModelTarget`](@ref)). Making out-of-plane "crossovers" can also be a bit involved, so there's a helper method [`SolidModels.staple_bridge_postrendering`](@ref) to generate the postrendering operations for a basic "staple" configuration.

The 2D-to-3D pipeline is one reason to work with "native" geometry in a `CoordinateSystem`, rather than discretizing everything into `Polygon`s as we would for a `Cell`. When we render curved Paths and rounded shapes to a `SolidModel`, circular arcs in paths and rounded corners are represented as exact circular arcs, and arbitrary curves are approximated with cubic B-splines. This not only keeps model size down but also allows Gmsh to make better meshes.

Moreover, when DeviceLayout.jl renders path segments and certain other entities, it automatically sets mesh sizing information to help Gmsh make better meshes. You can also annotate entities with the [MeshSized](@ref) style to provide such information manually.

See [API Reference: SolidModels](@ref api-solidmodels).

## [Geometry-level layout](@id dataflow-geometry)

It may be easier to understand the flow of data with a diagram. Here's one for the "hello world" workflow, working directly with `Cell`s:

```@raw html
<img src="../assets/cell_dataflow.jpg"/>
```

And here's a diagram for the more typical `CoordinateSystem` workflow:

```@raw html
<img src="../assets/coordinatesystem_dataflow.jpg"/>
```
