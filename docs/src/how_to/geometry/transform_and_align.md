# How to Transform and Align Geometry

This guide shows how to move, rotate, scale, and align shapes.

## Transformations

### Translation (Moving)

```julia
using DeviceLayout, DeviceLayout.PreferredUnits
using CoordinateTransformations

rect = centered(Rectangle(50μm, 30μm))

# Move by (100μm, 50μm)
moved = Translation(100μm, 50μm)(rect)
```

### Rotation

```julia
# Rotate 45 degrees around origin
rotated = Rotation(45°)(rect)

# Rotate around a specific point
center = Point(25μm, 15μm)
rotated_around = Translation(center) ∘ Rotation(45°) ∘ Translation(-center)
result = rotated_around(rect)
```

### Scaling

```julia
# Uniform scale
scaled = LinearMap(2.0 * I)(rect)  # 2x in both directions

# Non-uniform scale
scaled_xy = LinearMap([2.0 0; 0 0.5])(rect)  # 2x in x, 0.5x in y
```

### Mirroring

```julia
# Mirror across x-axis
mirrored_x = LinearMap([1 0; 0 -1])(rect)

# Mirror across y-axis
mirrored_y = LinearMap([-1 0; 0 1])(rect)
```

## Alignment

Use the `Align` module for relative positioning:

```julia
r1 = Rectangle(100μm, 50μm)
r2 = Rectangle(30μm, 30μm)

# Place r2 above r1 (touching)
r2_above = Align.above(r2, r1)

# Place r2 below r1 with gap
r2_below = Align.below(r2, r1, offset=10μm)

# Place r2 to the right of r1, centered vertically
r2_right = Align.rightof(r2, r1, centered=true)

# Flush alignments
r2_flush = Align.flushtop(r2, r1)  # Align top edges
```

## Composing Transformations

```julia
# Chain transformations with ∘
transform = Translation(100μm, 0μm) ∘ Rotation(45°)
result = transform(rect)
```

## See Also

- [Create Custom Shapes](create_custom_shapes.md)
- [Transformations Reference](@ref)
