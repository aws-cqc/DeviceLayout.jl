# Experimental simulation-agnostic solid models

`DeviceLayout.SolidModelsExperimental` is an opt-in pipeline that separates geometry and
mesh generation from simulator configuration. It produces a `SolidModel` plus a
schema-versioned metadata dictionary. Concrete process stacks, material-property databases,
Palace configuration, and downstream translation are intentionally outside DeviceLayout.

!!! warning "Experimental API"
    This API may change before DeviceLayout 2.0. The existing `SemanticMeta`,
    `ProcessTechnology`, `SchematicDrivenLayout.SolidModelTarget`, and `ArtworkTarget`
    pipeline is unchanged.

## Layer references, locators, and source stacks

Geometry participating in this pipeline uses `LayerRef`; legacy `SemanticMeta` geometry is
ignored so migrated and legacy components can coexist:

```julia
using DeviceLayout
using DeviceLayout.SolidModelsExperimental:
    Cut,
    DIELECTRIC,
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
port_geometry = Rectangle(5μm, 20μm) |> WithDirection(90°)
place!(coordinate_system, port_geometry, LayerRef(:port))
place!(coordinate_system, Locator(center(bounds(port_geometry))), LumpedPort(:port, "jj"))
place!(coordinate_system, Locator(0μm, 0μm), Terminal(:metal, "island"))
```

A `Locator` marks a single point; locator resolution only uses that point, so no bounding
shape is needed. `LumpedPort` and `WavePort` locators must sit inside directed port
geometry. The required `WithDirection` style belongs to that port geometry, not the locator.
Its angle is transformed through placement rotations and reflections and serialized as
`[cos(theta), sin(theta), 0.0]`.

The layer is a plain `Symbol`. A `SourceStack` is authoritative for its assembly level,
z position, material class, declared thickness, and output visibility:

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

Every placed `LayerRef` and locator layer must exist in the stack, and every level referenced
by a source layer must exist in `stack.levels`. A declared `thickness` (or a level span
`level=a => b`) describes the brick a layer forms in the final stack; it is built by an
explicit `Extrude` operation, and rendering fails if a declared thickness is never extruded
or an extrusion disagrees with it. `solidmodel=false` hides a layer from mesh
geometry and returned metadata while leaving it eligible for GDS. Conversely,
`gds_meta=nothing` hides only artwork. Locators are excluded from mesh geometry and resolved
against finalized geometry.

`SemanticMeta` and its `facing` behavior remain unchanged but are ignored by this pipeline.
`LayerRef` has no `facing` behavior because `SourceStack` owns vertical placement.

## Rendering

The target stores exactly the stack and layer-level operations:

```julia
target = SolidModelTarget(stack)
metadata = render!(solid_model, checked_schematic, target)
```

Target operations describe the complete construction sequence: extrusion, layer-level
booleans, boundary extraction, hollowing, restriction, translation, revolution, or periodic
pairing. They are compiled to physical-group operations. Operations are immutable, typed
objects; invalid argument and keyword types are rejected when they are constructed. For
example:

```julia
ops = [
    Extrude(:substrate),
    Extrude(:bounding_volume),
    Cut(:vacuum, :bounding_volume, :substrate),
    GetBoundary(:xmin, :vacuum; direction="x", position="min"),
    Translate(:shifted_port, :port, 10μm, 0μm, 0μm)
]
target = SolidModelTarget(stack, ops)
```

The public operation types are:

| Type | Meaning |
|:--|:--|
| `Extrude(source)`, `Extrude(source, dz)`, `Extrude(source; to_level, offset)`, or `Extrude(destination, source, …)` | Extrude a 1D or 2D layer along z. A source-stack layer is built to its declared thickness or level span; an explicit `dz` or target level is required for generated layers and must agree with the declaration otherwise. The one-layer forms operate in place; 3D sources are rejected. |
| `Hollow(layer)` | Replace a 3D layer by its boundary shell and remove the enclosed volume from the model after fragmentation, so the interior is absent from the mesh regardless of which other volumes it overlaps. Shells are `GetBoundary(:x, :x); Extrude(:x)`. |
| `Cut(destination, object, tools)` | Subtract tool layers from an object layer. One tool may be a symbol; multiple tools must be grouped in a tuple or vector. Follow it with `Remove` to remove inputs. |
| `Fuse(source)` or `Fuse(destination, sources)` | Union one or more source layers; the one-layer form heals a layer in place. Other sources remain unless removed explicitly later. |
| `SolidModelsExperimental.Intersect(destination, object, tool)` | Compute the OCC intersection of two layers. Follow it with `Remove` to consume either input layer. |
| `GetInterface(destination, object, tool)` | Resolve a deferred interface after fragmentation. The destination must be new, and the inputs' PG identities must remain available through deferred execution. |
| `RestrictTo(volume)` | Restrict the model to a 3D bounding-volume layer. |
| `GetBoundary(destination, source; combined, oriented, recursive, direction, position)` | Extract boundaries into a new destination or replace the source in place. |
| `Translate(source, dx, dy, dz)` or `Translate(destination, source, dx, dy, dz)` | Translate a layer. The one-layer form moves it in place; a distinct destination receives a copy and the source is preserved. |
| `Remove(source; remove_entities)` | Remove a layer, or do nothing if it is absent. |
| `Revolve(source, origin, axis, angle)` or `Revolve(destination, source, origin, axis, angle)` | Sweep a layer around an axis, retaining swept entities one dimension above the source. The one-layer form operates in place. Three-dimensional sources are rejected. |
| `SetPeriodic(first, second)` | Pair two distinct 2D periodic layers. |

Until rendering, every layer holds exactly one physical group named after the layer, and every
operation produces one layer from its inputs. A destination must therefore be either new or
one of the operation's own inputs, in which case the result replaces that input; naming an
existing unrelated layer is rejected. To accumulate several results in one layer, compute them
into distinct layers and `Fuse` them. Layer operations have geometric and source-lifetime
semantics but no user-facing PG identity semantics: after rendering, deduplication and locator
resolution may split a layer into several PGs, and functional identity is applied by
terminal, ground, tag, and port locators.

Generated destinations need not appear in `SourceStack`, but every referenced source must
exist in the compiler registry when the operation is reached. Typed constructors reject
malformed operations before compilation, while unavailable source layers and existing
destinations are rejected before Gmsh rendering begins.

The schematic renderer builds a private geometry/reference copy. It does not mutate the
input schematic or component geometry caches. Each graph-node placement prefixes nonempty
locator names with its stable node ID (for example, `q1.island`). The v1 contract applies one
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
position. `LayerRef` carries no datatype index.

## Migrating from the legacy pipeline

Migration is not a target substitution. Components opt geometry in by replacing
`SemanticMeta` with `LayerRef`, add explicit locators, map opposite-chip variants to layer
symbols, and supply a complete `SourceStack`. Unported `SemanticMeta` geometry is ignored,
allowing gradual component migration. The legacy technology and targets remain supported.

See `examples/solidmodels_experimental.jl` for a small end-to-end example.
