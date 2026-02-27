# How to Export to GDS

This guide shows how to save layouts to GDSII format for fabrication.

## Basic Export

```julia
using DeviceLayout, FileIO

# Save cell to GDS
save("output.gds", cell)
```

## From Schematic

```julia
using DeviceLayout.SchematicDrivenLayout

# Render schematic to cell
cell = Cell("device", nm)
render!(cell, schematic, target)

# Flatten before saving (recommended for non-Manhattan rotations)
flatten!(cell, max_copy=100)

save("device.gds", cell)
```

## Flattening Options

```julia
# Full flatten (increases file size)
flatten!(cell)

# Partial flatten (keep frequently referenced cells)
flatten!(cell, max_copy=100)  # Don't flatten cells with >100 references
```

## Database Units

```julia
# Cells default to 1nm database units
cell = Cell("device", nm)  # 1nm precision

# For finer resolution
cell = Cell("fine", pm)  # 1pm precision
```

## See Also

- [Visualize Layouts](visualize_layouts.md)
- [File I/O Reference](@ref)
