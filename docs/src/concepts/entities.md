# [Entities and Metadata](@id entities-concept)

This page explains how DeviceLayout represents geometry and its associated metadata.

## What is an Entity?

An **entity** is any geometric object with associated metadata. The core abstraction is:

```julia
entity = (geometry, metadata)
```

Where:
- **geometry**: A shape like `Rectangle`, `Polygon`, `Circle`, or `Path`
- **metadata**: Information about the layer, style, or meaning

## Metadata Types

### GDSMeta

For direct GDS layer assignment:

```julia
GDSMeta(layer)           # layer number only
GDSMeta(layer, datatype) # layer and datatype
```

Example:
```julia
render!(cell, rect, GDSMeta(0))      # Layer 0, datatype 0
render!(cell, rect, GDSMeta(1, 5))   # Layer 1, datatype 5
```

### SemanticMeta

For design-time semantic meaning (recommended for schematic-driven design):

```julia
SemanticMeta(:metal_negative)
SemanticMeta(:junction)
SemanticMeta(:chip_area)
```

Semantic metadata is converted to GDS layers when rendering to a `LayoutTarget`.

### Styled Entities

Apply rendering styles to geometry:

```julia
# Mesh sizing for simulation
MeshSized(h=5μm)(Rectangle(50μm, 20μm))

# Rounded corners
Rounded(5μm)(Rectangle(50μm, 20μm))
```

## Entity Styles

Styles modify how entities are processed:

| Style | Effect |
|-------|--------|
| `MeshSized(h, α)` | Controls mesh density for simulation |
| `Rounded(r)` | Applies rounded corners |
| `Decorated` | Attaches decorations to paths |

Styles can be composed:

```julia
MeshSized(h=5μm)(Rounded(2μm)(Rectangle(50μm, 20μm)))
```

## Layer Functions

Query metadata:

```julia
layer(meta)      # Get layer name/number
meta_str(meta)   # String representation
facing(meta)     # Flip to other side (flip-chip)
```

## The Rendering Pipeline

Entities flow through:

1. **Creation**: `Rectangle(100μm, 50μm)` + `SemanticMeta(:metal)`
2. **Placement**: `place!(cs, entity, metadata)`
3. **Transformation**: Applied during `render!`
4. **Layer mapping**: `Target` maps semantic → GDS
5. **Output**: Written to GDS file

## See Also

- [Coordinate Systems](coordinate_systems.md)
- [The Render Pipeline](rendering.md)
