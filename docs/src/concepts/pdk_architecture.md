# [PDK Architecture](@id pdk-architecture)

A Process Design Kit (PDK) packages everything needed to design for a specific fabrication process.

## PDK Structure

```
┌─────────────────────────────────────────────────┐
│                      PDK                         │
├─────────────────────────────────────────────────┤
│  Layer Vocabulary    │  Semantic layer names     │
├─────────────────────────────────────────────────┤
│  ProcessTechnology   │  Layer properties,        │
│                      │  z-heights, thickness     │
├─────────────────────────────────────────────────┤
│  Targets             │  Rendering configurations │
│  - ArtworkTarget     │  (GDS output)             │
│  - SolidModelTarget  │  (3D simulation)          │
├─────────────────────────────────────────────────┤
│  Components          │  PDK-specific building    │
│                      │  blocks                   │
└─────────────────────────────────────────────────┘
```

## Layer Vocabulary

Named layers with semantic meaning:

```julia
SemanticMeta(:metal_negative)   # Etch away metal
SemanticMeta(:junction)         # Josephson junctions
SemanticMeta(:chip_area)        # Substrate bounds
```

Benefits:
- Design without knowing GDS layer numbers
- Change mappings without changing designs
- Self-documenting layer usage

## ProcessTechnology

Defines physical properties:

```julia
ProcessTechnology(
    layer_properties,  # NamedTuple: layer → GDSMeta
    options            # Additional configuration
)
```

For simulation:
- z-heights (where layers sit)
- thicknesses (extrusion amounts)
- Material properties

## Targets

### ArtworkTarget

For GDS fabrication output:

```julia
ArtworkTarget(technology, options)
```

Maps semantic layers to GDS layers.

### SolidModelTarget

For 3D simulation:

```julia
SolidModelTarget(
    technology;
    postrender_ops,    # 3D operations
    bounding_layers,   # Simulation domain
    substrate_layers   # Substrate definition
)
```

## Why PDKs?

| Benefit | Description |
|---------|-------------|
| **Standardization** | Team uses same layers and components |
| **Separation** | Design logic separated from fab details |
| **Versioning** | Track changes to process parameters |
| **Sharing** | Distribute validated components |

## See Also

- [Tutorial: Creating a PDK](../tutorials/creating_a_pdk.md)
- [ExamplePDK](../examples/examplepdk.md)
