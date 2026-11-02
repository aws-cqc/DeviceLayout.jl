# Solid Models (Experimental)

`DeviceLayout.SolidModelsExperimental` renders a schematic to a `SolidModel` and returns
metadata describing its layers and the surfaces selected by locators.

!!! warning "Experimental API"
    This API may change before DeviceLayout 2.0.

The module exports nothing; import names from `DeviceLayout.SolidModelsExperimental`. See the
[Experimental Solid Model API Reference](@ref solidmodels-experimental-api).

## Layer references, locators, and source stacks

Geometry is placed on a layer with `LayerRef`; geometry with `SemanticMeta` is ignored.
Locators are `Locator` points carrying `Terminal`, `Ground`, `Tag`, `WavePort`, or
`LumpedPort` metadata:

```julia
using DeviceLayout
using DeviceLayout.SchematicDrivenLayout
using DeviceLayout.SolidModelsExperimental:
    Cut,
    DIELECTRIC,
    Extrude,
    GetBoundary,
    LayerRef,
    Locator,
    LumpedPort,
    METAL,
    NULL,
    SolidModelTarget,
    SourceLayer,
    SourceStack,
    Terminal,
    Translate
import JSON
using Unitful: μm, °

coordinate_system = CoordinateSystem("device", μm)
place!(coordinate_system, Rectangle(100μm, 100μm), LayerRef(:metal))
port_geometry = Rectangle(Point(100μm, 40μm), Point(105μm, 60μm)) |> WithDirection(90°)
place!(coordinate_system, port_geometry, LayerRef(:port))
place!(coordinate_system, Locator(center(bounds(port_geometry))), LumpedPort(:port, "jj"))
place!(coordinate_system, Locator(50μm, 50μm), Terminal(:metal, "island"))
footprint = Rectangle(Point(-50μm, -50μm), Point(200μm, 150μm))
place!(coordinate_system, footprint, LayerRef(:substrate))
place!(coordinate_system, footprint, LayerRef(:bounding_volume))
```
A `LumpedPort` locator must lie inside the bounding box of exactly one `WithDirection`-styled
entity on the port's layer. That style's angle, transformed by placement, is serialized as
`[cos(theta), sin(theta), 0.0]`.

A `SourceStack` gives each layer its material, assembly level, z offset, thickness, and GDS
layer:

```julia
stack = SourceStack(
    :metal => SourceLayer(METAL; level=1, gds_meta=GDSMeta(10, 0)),
    :port => SourceLayer(NULL; level=1, gds_meta=GDSMeta(11, 0)),
    :substrate => SourceLayer(
        DIELECTRIC;
        level=1,
        thickness=-500μm,
        gds_meta=nothing
    ),
    :bounding_volume => SourceLayer(
        NULL;
        level=1,
        offset=-500μm,
        thickness=1000μm,
        gds_meta=nothing
    );
    levels=(1 => 0μm, 2 => 500μm)
)
```
Every `LayerRef` and locator layer must be in the stack. Lengths are either all unitful or
all unitless, in micrometers. Only `METAL` affects rendering: terminal selection uses the 2D
`METAL` layers.

A layer's `thickness` (or level span `level=a => b`) is built by an `Extrude` operation that
must agree with it; rendering fails if such a layer is still unextruded after the last
operation. `solidmodel=false` omits a layer from the solid model, and `gds_meta=nothing` omits
it from artwork.

## Rendering

A `SolidModelTarget` holds the stack and the layer operations applied to it, in order:

```julia
ops = [
    Extrude(:substrate),
    Extrude(:bounding_volume),
    Cut(:vacuum, :bounding_volume, :substrate; remove_object=true),
    GetBoundary(:xmin, :vacuum; direction="x", position="min"),
    Translate(:shifted_port, :port, 10μm, 0μm, 0μm)
]
target = SolidModelTarget(stack, ops)

graph = SchematicGraph("device")
add_node!(graph, BasicComponent(coordinate_system); base_id="q1")
checked_schematic = check!(plan(graph; log_dir=nothing))
solid_model = SolidModel("device"; overwrite=true)
metadata = render!(solid_model, checked_schematic, target)
```
| Type | Meaning |
|:--|:--|
| `Extrude(source)`, `Extrude(source, dz)`, `Extrude(source; to_level, offset)`, `Extrude(destination, source)`, `Extrude(destination, source, dz)`, or `Extrude(destination, source; to_level, offset)` | Extrude a 1D or 2D layer along z, to its declared thickness or level span by default. |
| `Hollow(layer)` | Replace a 3D layer by its boundary, removing its interior from the final model. |
| `Cut(destination, object, tools; remove_object, remove_tool)` | Subtract a layer or a tuple or vector of layers from `object`. |
| `Fuse(source)` or `Fuse(destination, sources; remove_sources)` | Union a tuple or vector of layers, or merge a layer's own overlapping geometry. |
| `SolidModelsExperimental.Intersect(destination, object, tool; remove_object, remove_tool)` | Intersect two layers. The name must be qualified, since DeviceLayout also has an `Intersect` module. |
| `GetInterface(destination, object, tool)` | Compute the interface between two layers of the final model. |
| `RestrictTo(volume)` | Restrict the model to a 3D layer. |
| `GetBoundary(source; combined, oriented, recursive, direction, position)` or `GetBoundary(destination, source; ...)` | Extract the boundary of a layer, optionally only its faces at one end of an axis. `exterior_boundaries(volume)` returns the six operations extracting a volume's faces into `:EXTBND_XMIN` through `:EXTBND_ZMAX`. |
| `Translate(source, dx, dy, dz)` or `Translate(destination, source, dx, dy, dz)` | Translate a layer. |
| `Remove(source; remove_entities)` | Remove a layer. |
| `Revolve(source, origin, axis, angle)` or `Revolve(destination, source, origin, axis, angle)` | Revolve a layer around an axis. |
| `SetPeriodic(first, second)` | Make two 2D layers periodic. |

A destination must be new or one of the operation's inputs, which it replaces. New
destinations need not be in the stack. The booleans' `remove_*` flags consume their inputs;
use them rather than a later `Remove`, which would also remove geometry that passed through
the boolean unchanged.

Terminal selection builds the connected components of the 2D layers named after `METAL`
stack layers, so a generated layer takes part only if it replaces such a layer (for example,
`Cut(:metal, :metal, :etch)`), and extruded metal only once it is `Hollow`ed. Each component
must contain a `Terminal` or `Ground` locator, and each such locator must lie on a component.
Components with a `Ground` locator are reported under `ground`, and the others under
`terminals`. The `select_terminals`, `select_tagged_surfaces`, and `select_ports` keywords of
`render!` turn off each kind of selection.

Locator names are prefixed with the ID of their schematic node (for example, `q1.island`).
`Tag` and port names must be unique, so such a locator in a structure referenced twice within
one node throws an `ArgumentError`.

`render!` returns the metadata as a `Dict{String, Any}`. To save it and the model:

```julia
open("sm_metadata.json", "w") do io
    JSON.print(io, metadata, 4)
end
DeviceLayout.save("model.xao", solid_model)
```
The metadata has the sections `metadata` (schema version and length units, micrometers),
`physical_groups`, `layers`, `tagged`, `ports`, `terminals`, and `ground`. Tags and ports are
keyed by locator name, with a `LumpedPort` whose `index` is not 1 keyed `name_index`.
Terminal and ground components are keyed `METAL_CC__` followed by a hash of their entities.
The schema is `schemas/sm_metadata.schema.json`.

## Artwork

Render artwork from the stack:

```julia
cell = Cell("artwork", μm)
render!(
    cell,
    coordinate_system,
    stack;
    levels=[1, 2],
    level_increment=GDSMeta(100, 10)
)
```
Each layer is rendered to its `gds_meta`. When `levels` has more than one entry, a layer's
GDS layer and datatype are offset by `(level - 1) * level_increment`, where `level` is the
layer's first level (or 1 if that is lower).

## Migrating from the legacy pipeline

To migrate a component, replace its `SemanticMeta` with `LayerRef`, add locators, map
opposite-chip variants to layer symbols, and add its layers to a `SourceStack`. Unmigrated
`SemanticMeta` geometry is ignored, so components can be migrated one at a time.

See `examples/solidmodels_experimental.jl` for an end-to-end example.
