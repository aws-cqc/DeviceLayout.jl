# Coordinate Systems

Coordinate systems (subtypes of `AbstractCoordinateSystem`) group geometric objects into a single structure with a common origin and coordinate axes. They can contain references to other [`DeviceLayout.GeometryStructure`](@ref)s, a [`GeometryEntity`](@ref) list, and metadata for each entity.

## AbstractCoordinateSystems

```@docs
    DeviceLayout.AbstractCoordinateSystem
```

Because these are subtypes of `GeometryStructure`, they can be used with the [transformation interface](./transformations.md) as well as the [structure interface](./geometry.md#Structures) including [`bounds`](@ref) and other operations.

DeviceLayout.jl defines the concrete [`CoordinateSystem`](@ref) as a backend-agnostic (or "native") representation that can be converted to other representations as necessary, and [`Cell`](@ref) as the concrete representation corresponding to the GDSII format. There is also the subtype [`SchematicDrivenLayout.Schematic`](@ref), which composes a `CoordinateSystem` with schematic-level information about component connectivity.

### Referenced coordinate systems

Coordinate systems can be [arrayed or referenced](./geometry.md#References) within other coordinate systems. These can be accessed in the array returned by `refs(cs)` or by indexing the parent coordinate system or reference with the referenced structure's name, as in `cs["referenced_cs"]["deeper_cs"]`.

The methods `addref!` and `addarr!` are provided for adding structure references and array references.

```@docs
    addref!
    addarr!
```

### Flattening

Sometimes it's also helpful use the [`flatten`](@ref) operation to produce an equivalent coordinate system with no references—that is, with all its elements at the top level. `CoordinateSystem`s and `Cell`s can also be flattened in place with `flatten!`.

```@docs
    flatten!(::DeviceLayout.AbstractCoordinateSystem)
```

## Cells

`Cell`s are the concrete `AbstractCoordinateSystem` representation corresponding to
the GDSII format. Accordingly, they hold `Polygon`s with metadata of type `GDSMeta` (added using `render!`). They can also hold [`Text` objects](./texts.md#texts), and they can be saved directly to a `.gds` file.

```@docs
    Cell
    Cell(::AbstractString)
    Cells.dbscale(::Cell)
    Cells.dbscale(::Cell, ::Cell, ::Cell...)
    CellArray
    CellReference
    GDSMeta
    gdslayers(::Cell)
    render!(::Cell, ::Polygon, ::GDSMeta)
    DeviceLayout.save(::File{format"GDS"}, ::Cell, ::Cell...)
```

The type parameter `S` of a `Cell{S}` object determine the type of the coordinates of all polygons in a cell, including the units and whether integer or floating-point values are used. Currently, you cannot do a whole lot (particularly with regard to paths) if the cell has integer coordinates. However, they do have an inherent advantage because the coordinates are exact, and ultimately the GDSII file represents shapes with integer coordinates.

Separately, the `Cell` has a "database scale" (the `dbscale` field) applied when saving that defaults to `1nm` but can be changed.

For most cases, if you want to use units, `Cell("my_cell_name", nm)`
is a good way to construct a cell which will ultimately have all coordinates
rounded to the nearest `nm` when exported into GDSII. You can add polygons
with whatever length units you want to such a cell, and the coordinates will
be converted automatically to `nm`.

If you don't want units, just construct the cell with a name only:
`Cell("my_cell_name")` will return a `Cell{Float64}` object unless you have set a [unit preference](units.md#Unit-preferences). In this case too,
the ultimate database resolution is `1nm`; until exporting the cell into a GDSII
file, the coordinates are interpreted to be in units of `1μm`.

When saving cells to disk, keep in mind that cells should have unique names.
We don't have an automatic renaming scheme implemented to avoid clashes. To
help with this, we provide a function [`uniquename`](@ref) to generate unique
names based on human-readable prefixes.

When saving cells to disk, there will be a tree of interdependencies and logically
one would prefer to write the leaf nodes of the tree before any dependent cells.
These functions are used to traverse the tree and then find the optimal ordering.

```@docs
    traverse!
    order!
```

## CoordinateSystems

`CoordinateSystem`s are "DeviceLayout-native" `AbstractCoordinateSystem`s. Unlike `Cell`s, they can hold any `GeometryEntity`, not just `Polygon`s, as well as references to any `GeometryStructure`, not just `Cell`s. The idea is to work with an exact or logical representation of geometric elements as long as possible, deferring decisions about output representations until rendering time. This allows things like calculating intersection points between `Path`s in a hierarchy of `CoordinateSystem`s and references, or rendering exact curves to a `SolidModel`.

Because of this, we add entities to a `CoordinateSystem` with `place!` rather than `render!`. The different verb is meant to convey that the entity is added as-is rather than potentially converted to some other representation. (For convenience, `render!` still works with `CoordinateSystem`s, but it's just an alias for `place!`.)

```@docs
    CoordinateSystem
    CoordinateSystemReference
    CoordinateSystemArray
    place!
```

As with a `Cell{S}`, a `CoordinateSystem{S}` has a coordinate type parameter `S`.
Unlike `Cell`s, a `CoordinateSystem` is not tied to a database unit (a GDSII concept).

### Semantic metadata and rendering to cells

Since `CoordinateSystem`s are intended to be backend-agnostic, a useful pattern is to give
coordinate objects "semantic" metadata, consisting of a layer name `Symbol` as well as `level` and `index` attributes.

```@docs
    SemanticMeta
    layer
    layerindex
    layername
    level
```

A `CoordinateSystem` (or any `GeometryStructure`) can be rendered to a `Cell` for output to a GDS format by mapping its metadata to GDSMeta. Specifically, during rendering, an `entity::GeometryEntity` with metadata `SemanticMeta(:my_layer)` will be rendered as one or more polygons (`to_polygons(entity)`). These polygons will have GDSMeta (layer number and datatype) determined by `map_meta(SemanticMeta(:my_layer))`, where `map_meta` is a function supplied as a keyword argument to `render!`. A default hash-based map is supplied to allow quick visualizations when the specific output GDS layers don't matter.

```@docs
    Cell(::CoordinateSystem{S}) where {S}
    render!(::Cell, ::DeviceLayout.GeometryStructure)
    DeviceLayout.default_meta_map
    gdslayers(::GeometryStructure)
```

Note that `Cell`s inherit the names of rendered `CoordinateSystem`s, so the original coordinate systems ought to have unique names (for example using [`uniquename`](@ref)).
