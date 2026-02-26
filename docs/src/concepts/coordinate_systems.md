# Coordinate Systems

Coordinate systems (subtypes of `AbstractCoordinateSystem`) group geometric objects into a single structure with a common origin and coordinate axes. They can contain references to other [`DeviceLayout.GeometryStructure`](@ref)s, a [`GeometryEntity`](@ref) collection, and metadata for each entity.

## AbstractCoordinateSystems

Because these are subtypes of `GeometryStructure`, they can be used with the [transformation interface](./transformations.md) as well as the [structure interface](./geometry.md#Structures) including [`bounds`](@ref) and other operations.

DeviceLayout.jl defines the concrete [`CoordinateSystem`](@ref) as a backend-agnostic (or "native") representation that can be converted to other representations as necessary, and [`Cell`](@ref) as the concrete representation corresponding to the GDSII format. There is also the subtype [`SchematicDrivenLayout.Schematic`](@ref), which composes a `CoordinateSystem` with schematic-level information about component connectivity.

| | CoordinateSystem | Cell |
|---|---|---|
| **Elements** | Any `GeometryEntity` | `Polygon` only |
| **Metadata** | Any `Meta` (`SemanticMeta`, `GDSMeta`, ...) | `GDSMeta` only |
| **References** | To any `GeometryStructure` (`CoordinateSystem`, `Path`, ...) | `Cell` only |
| **Use case** | Design-time layout, semantic layers | GDS file output |
| **Extra fields** | — | `texts`, `dbscale` |

See [Coordinate Systems API](@ref api-coordinate-systems) and [Cells API](@ref api-cells).

### References

Coordinate systems can be [arrayed or referenced](./geometry.md#References) within other coordinate systems. These can be accessed in the array returned by `refs(cs)` or by indexing the parent coordinate system or reference with the referenced structure's name, as in `cs["referenced_cs"]["deeper_cs"]`.

The methods [`addref!`](@ref) and [`addarr!`](@ref) are provided for adding structure references and array references:

```julia
addref!(parent_cs, child_cs)                          # at origin
addref!(parent_cs, child_cs, Point(100nm, 0nm))       # with offset
addref!(parent_cs, child_cs; rot=90°, xrefl=true)     # with rotation and reflection
```

### Flattening

Sometimes it's also helpful use the [`flatten`](@ref) operation to produce an equivalent coordinate system with no references—that is, with all its elements at the top level. `CoordinateSystem`s and `Cell`s can also be flattened in place with [`flatten!`](@ref).

## Cells

`Cell`s are the concrete `AbstractCoordinateSystem` representation corresponding to
the GDSII format. Accordingly, they hold `Polygon`s with metadata of type `GDSMeta` (added using `render!`). They can also hold [`Text` objects](./texts.md#texts), and they can be saved directly to a `.gds` file.

The type parameter `S` of a `Cell{S}` object determines the type of the coordinates of all polygons in a cell, including the units and whether integer or floating-point values are used. Currently, you cannot do a whole lot (particularly with regard to paths) if the cell has integer coordinates. However, they do have an inherent advantage because the coordinates are exact, and ultimately the GDSII file represents shapes with integer coordinates.

Separately, the `Cell` has a "database scale" (the `dbscale` field) applied when saving that defaults to `1nm` but can be changed.

For most cases, if you want to use units, `Cell("my_cell_name")`
is a good way to construct a cell which will ultimately have all coordinates
rounded to the nearest `nm` when exported into GDSII. You can add polygons
with whatever length units you want to such a cell, and the coordinates will
be converted automatically to [the unit specified in project preferences](./units.md#Unit-preferences) (default `nm`).

If you don't want units, construct the cell with 
`Cell{Float64}("my_cell_name")` (or set your unit preference to "PreferNoUnits"). In this case too,
the ultimate database resolution is `1nm`; until exporting the cell into a GDSII
file, the coordinates are interpreted to be in units of `1μm`.

When saving cells to disk, keep in mind that cells should have unique names.
To help with this, we provide a function [`uniquename`](@ref) to generate unique
names based on human-readable prefixes. You can also use `save("mycell.gds", cell; options=GDSWriterOptions(rename_duplicates=true))` to automatically provide unique names when saving. (That setting is not the default because duplicate names may indicate a problem in geometry construction; a message about the duplicate name is shown either way.) [`GDSWriterOptions`](@ref) provides some additional control over warnings shown when saving Cells.

When saving cells to disk, there will be a tree of interdependencies and logically
one would prefer to write the leaf nodes of the tree before any dependent cells.
The [`traverse!`](@ref) and [`order!`](@ref) functions are used to traverse the tree and then find the optimal ordering.

## CoordinateSystems

`CoordinateSystem`s are "DeviceLayout-native" `AbstractCoordinateSystem`s. Unlike `Cell`s, they can hold any `GeometryEntity`, not just `Polygon`s, as well as references to any `GeometryStructure`, not just `Cell`s. The idea is to work with an exact or logical representation of geometric elements as long as possible, deferring decisions about output representations until rendering time. This allows things like calculating intersection points between `Path`s in a hierarchy of `CoordinateSystem`s and references, or rendering exact curves to a `SolidModel`.

Because of this, we add entities to a `CoordinateSystem` with `place!` rather than `render!`. The different verb is meant to convey that the entity is added as-is rather than potentially converted to some other representation. (For convenience, `render!` still works with `CoordinateSystem`s, but it's just an alias for `place!`.)

```julia
cs = CoordinateSystem("my_layout")
place!(cs, Rectangle(10nm, 5nm), SemanticMeta(:metal))
place!(cs, my_polygon, :via)  # Symbol shorthand for SemanticMeta(:via)
```

As with a `Cell{S}`, a `CoordinateSystem{S}` has a coordinate type parameter `S`.
Unlike `Cell`s, a `CoordinateSystem` is not tied to a database unit (a GDSII concept).

### Semantic metadata and rendering to cells

Since `CoordinateSystem`s are intended to be backend-agnostic, a useful pattern is to give
coordinate objects "semantic" metadata, consisting of a layer name `Symbol` as well as `level` and `index` attributes.

A `CoordinateSystem` (or any `GeometryStructure`) can be rendered to a `Cell` for output to a GDS format by mapping its metadata to `GDSMeta`. Specifically, during rendering, an `entity::GeometryEntity` with metadata `SemanticMeta(:my_layer)` will be rendered as one or more polygons (`to_polygons(entity)`). These polygons will have `GDSMeta` (layer number and datatype) determined by `map_meta(SemanticMeta(:my_layer))`, where `map_meta` is a function supplied as a keyword argument to `render!`. The map can also be constructed automatically by providing `render!` with a [`LayoutTarget`](@ref) containing a layer record (among other rendering options).

A default hash-based map to `GDSMeta` is supplied to allow quick visualizations when the specific output GDS layers don't matter.

Note that `Cell`s inherit the names of rendered `CoordinateSystem`s, so the original coordinate systems ought to have unique names (for example using [`uniquename`](@ref)).
