# How to Attach Structures to Paths

This guide shows how to place structures (like bridges) along paths.

## Basic Attachment

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Create a bridge cell
bridge = Cell("bridge", nm)
render!(bridge, centered(Rectangle(30μm, 10μm)), GDSMeta(1))

# Create path
p = Path(μm)
straight!(p, 500μm, Paths.CPW(10μm, 6μm))

# Attach at specific positions
attach!(p, CellReference(bridge), 100μm)  # Single position
attach!(p, CellReference(bridge), 100μm:100μm:400μm)  # Regular intervals
```

## Attach to Specific Segment

```julia
p = Path(μm)
straight!(p, 200μm, Paths.CPW(10μm, 6μm))
turn!(p, 90°, 50μm)
straight!(p, 200μm)

# Attach to segment i=2 (the turn)
attach!(p, CellReference(bridge), 25μm, i=2)
```

## Offset from Path Center

```julia
# Attach offset to one side
attach!(p, CellReference(bridge), 100μm, location=20μm)

# Attach on opposite side
attach!(p, CellReference(bridge), 100μm, location=-20μm)
```

## Using `simplify!` for Full-Path Attachment

```julia
p = Path(μm)
straight!(p, 200μm, Paths.CPW(10μm, 6μm))
turn!(p, 90°, 50μm)
straight!(p, 200μm)

# Combine segments 1-3 into a single compound segment
simplify!(p, 1:3)

# Now attach along the entire simplified path
attach!(p, CellReference(bridge), 50μm:50μm:pathlength(p) - 50μm)
```

## See Also

- [Create a CPW](create_cpw.md)
- [Paths Reference](@ref)
