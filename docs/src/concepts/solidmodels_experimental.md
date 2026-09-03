# Experimental simulation-agnostic solid models

`DeviceLayout.SolidModelsExperimental` is an opt-in pipeline that separates geometry and
mesh generation from simulator configuration. It produces a `SolidModel` plus a
schema-versioned metadata dictionary. Concrete process stacks, material-property databases,
Palace configuration, and downstream translation are intentionally outside DeviceLayout.

!!! warning "Experimental API"
    This API may change before DeviceLayout 2.0. The existing `SemanticMeta`,
    `ProcessTechnology`, `SchematicDrivenLayout.SolidModelTarget`, and `ArtworkTarget`
    pipeline is unchanged.

## Entity metadata and source stacks

Geometry participating in this pipeline uses `SolidModelsExperimental.EntityMeta`:

```julia
using DeviceLayout
using DeviceLayout.SolidModelsExperimental
import JSON
using Unitful: μm, °

coordinate_system = CoordinateSystem("device", μm)
metal = EntityMeta(:metal; name="island", role=Terminal())
port = EntityMeta(:port; name="jj", role=LumpedPort)
port_geometry = Rectangle(5μm, 20μm) |> WithDirection(90°)
place!(coordinate_system, port_geometry, port)
```

`LumpedPort` is a role, while its required in-plane orientation belongs to the geometry's
`WithDirection` style. The angle is measured counterclockwise from local +X and is transformed
through rotations and reflections during placement. Metadata serializes the final orientation
as `[cos(theta), sin(theta), 0.0]`. Occurrences that share one physical-group identity must
have equal final directions; otherwise give them distinct `EntityMeta` `name` or `index`
values.

The layer is a plain `Symbol`. A `SourceStack` is authoritative for its assembly level,
z position, material class, extrusion, and output visibility:

```julia
using Unitful: μm

stack = SourceStack(
    :metal => SourceLayer(METAL; level=1, gds_meta=GDSMeta(10, 0)),
    :port => SourceLayer(NULL; level=1, gds_meta=GDSMeta(11, 0)),
    :substrate => SourceLayer(
        DIELECTRIC;
        level=1,
        thickness=-500μm,
        gds_meta=nothing
    );
    levels=(1 => 0μm, 2 => 500μm)
)
```

Every placed `EntityMeta` layer must exist in the stack, and every level referenced by a
source layer must exist in `stack.levels`. Validation happens before Gmsh is invoked.
`solidmodel=false` hides a layer from mesh geometry and returned metadata while leaving it
eligible for GDS. Conversely, `gds_meta=nothing` hides only artwork. Locator roles
(`Terminal`, `Ground`, and `Tag`) are excluded from mesh geometry and retained for
post-fragmentation discovery.

Unlike `SemanticMeta`, `EntityMeta` has no `facing` behavior. Components used on another
chip must explicitly map to that chip's layer symbol.

## Rendering

The target stores exactly the stack and layer-level operations:

```julia
target = SolidModelsExperimental.SolidModelTarget(stack)
metadata = render!(solid_model, checked_schematic, target)
```

Source-layer extrusions are scheduled automatically. Target operations describe subsequent
layer-level booleans, boundary extraction, restriction, translation, revolution, or periodic
pairing and are compiled to physical-group operations. Operations are immutable, typed
objects; invalid argument and keyword types are rejected when they are constructed. For
example:

```julia
ops = [
    Difference(:vacuum, :bounding_volume, :substrate),
    Boundary(:xmin, :vacuum; direction="x", position="min"),
    Translate(:shifted_port, :port, 10μm, 0μm, 0μm)
]
target = SolidModelsExperimental.SolidModelTarget(stack, ops)
```

The public operation types are:

| Type | Meaning |
|:--|:--|
| `Extrude(layer)` | Extrude a source-stack layer using its configured thickness. |
| `Difference(destination, object, tools)` | Subtract tool layers from an object layer. One tool may be a symbol; multiple tools must be grouped in a tuple or vector. Follow it with `Remove` to remove inputs. |
| `Fuse(destination, sources)` | Union grouped source layers. Sources must be a tuple or vector. |
| `Interface(destination, object, tool)` | Resolve a deferred interface after fragmentation. |
| `Restrict(volume)` | Restrict the model to one bounding-volume layer. |
| `Boundary(destination, source; combined, oriented, recursive, direction, position)` | Extract boundaries. |
| `Translate(destination, source, dx, dy, dz; copy)` | Translate or copy-translate a layer. |
| `Remove(source; remove_entities)` | Remove a layer. |
| `Revolve(destination, source, origin, axis, angle)` | Revolve a layer. |
| `Periodic(first, second)` | Pair two periodic layers. |

A destination equal to a source layer replaces that layer for boundary, translation,
revolution, and single-source union operations. A new destination creates a generated layer;
an existing unrelated destination appends distinct content-addressed physical groups.
Difference also supports replacing its object or a tool layer. Multi-source union consumes
its source layers, and `Interface` creates or appends a deferred interface layer. Generated
destinations need not appear in `SourceStack`, but every referenced source must exist in the
compiler registry when the operation is reached. Typed constructors reject malformed
operations before compilation, while unavailable source layers and incompatible destination
dimensions are rejected before Gmsh rendering begins.

The schematic renderer builds a private geometry/reference copy. It does not mutate the
input schematic or component geometry caches. Each graph-node placement prefixes nonempty
entity names with its stable node ID (for example, `q1.island`). The v1 contract applies one
top-level node prefix recursively within that placement; arbitrary-depth composite paths are
not yet encoded. Locator centers retain every hierarchical reference occurrence and its
accumulated transform. The lower-level solid-model renderer performs the only flatten.

`render!` returns `Dict{String,Any}` and never writes metadata or model artifacts. Persist
metadata explicitly:

```julia
open("sm_metadata.json", "w") do io
    JSON.print(io, metadata, 4)
end
save("model.msh2", solid_model)
```

The contract is checked in at `schemas/sm_metadata.schema.json`; its initial
`schema_version` is `1.0.0`.

## Artwork

No experimental GDS target type is required. Render directly from the stack:

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

For multiple selected levels, both layer and datatype are offset by the selected-level
position. `EntityMeta.index` does not alter the datatype.

## Migrating from the legacy pipeline

Migration is not a target substitution. Components must first replace `SemanticMeta` with
`EntityMeta`, explicitly map opposite-chip variants to layer symbols, and supply a complete
`SourceStack`. The legacy technology and targets remain supported and are
not deprecated by this feature.

See `examples/solidmodels_experimental.jl` for a small end-to-end example.
