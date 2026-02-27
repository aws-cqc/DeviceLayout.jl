# How to Autofill Patterns

This guide shows how to fill empty areas with repeated patterns (like ground plane holes).

## Basic Autofill

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Create a pattern cell
hole = CoordinateSystem("hole")
place!(hole, Circle(5μm), SemanticMeta(:metal_negative))

# Define grid
x_grid = -4mm:100μm:4mm
y_grid = -4mm:100μm:4mm

# Create exclusion zone around existing geometry
exclusion = halo(schematic, 50μm)

# Fill the schematic
autofill!(schematic, hole, x_grid, y_grid, exclusion)
```

## Custom Exclusion

```julia
# Create exclusion function that ignores certain layers
exclusion = make_halo(50μm; ignore_layers=[:chip_area, :writeable_area])
```

## With Bounds

```julia
# Fill only within chip bounds
bnds = bounds(schematic, chip_node)
x_grid = (lowerleft(bnds).x + 100μm):100μm:(upperright(bnds).x - 100μm)
y_grid = (lowerleft(bnds).y + 100μm):100μm:(upperright(bnds).y - 100μm)

autofill!(schematic, hole, x_grid, y_grid, exclusion)
```

## See Also

- [Autofill Reference](@ref)
- [QPU17 Example](../../examples/qpu17.md)
