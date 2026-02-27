# How to Perform Boolean Operations

This guide shows how to combine shapes using Boolean operations.

## Union (Combine Shapes)

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

r1 = centered(Rectangle(60μm, 40μm))
r2 = Translation(30μm, 20μm)(centered(Rectangle(60μm, 40μm)))

# Combine into single shape
combined = union2d([r1, r2])

# Union of multiple shapes
shapes = [r1, r2, Circle(20μm)]
all_combined = union2d(shapes)
```

## Difference (Subtract)

```julia
# Subtract circle from rectangle
base = centered(Rectangle(100μm, 50μm))
hole = Circle(15μm)

result = difference2d(base, hole)

# Multiple subtractions
holes = [
    Translation(-30μm, 0μm)(Circle(10μm)),
    Translation(30μm, 0μm)(Circle(10μm))
]
result = difference2d(base, union2d(holes))
```

## Intersection (Overlap Only)

```julia
r1 = centered(Rectangle(60μm, 40μm))
r2 = Translation(20μm, 10μm)(centered(Rectangle(60μm, 40μm)))

# Keep only the overlapping region
overlap = intersect2d(r1, r2)
```

## XOR (Exclusive Or)

```julia
# Keep regions that are in one shape but not both
r1 = centered(Rectangle(60μm, 40μm))
r2 = Translation(20μm, 0μm)(centered(Rectangle(60μm, 40μm)))

xor_result = xor2d(r1, r2)
```

## Offset (Grow/Shrink)

```julia
rect = centered(Rectangle(100μm, 50μm))

# Grow by 10μm
grown = offset(rect, 10μm)

# Shrink by 5μm (negative offset)
shrunk = offset(rect, -5μm)
```

## See Also

- [Create Custom Shapes](create_custom_shapes.md)
- [Polygons Reference](@ref)
