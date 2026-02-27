# How to Create Custom Shapes

This guide shows how to create various geometric shapes in DeviceLayout.jl.

## Basic Shapes

### Rectangles

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Rectangle with lower-left at origin
rect = Rectangle(100μm, 50μm)

# Centered rectangle
centered_rect = centered(Rectangle(100μm, 50μm))

# Rectangle from two corner points
rect2 = Rectangle(Point(10μm, 20μm), Point(110μm, 70μm))
```

### Circles and Ellipses

```julia
# Circle with radius
circle = Circle(25μm)

# Ellipse with semi-axes
ellipse = Ellipse(50μm, 25μm)
```

### Regular Polygons

```julia
# Hexagon with circumradius 30μm
hexagon = RegularPolygon(6, 30μm)

# Pentagon
pentagon = RegularPolygon(5, 20μm)
```

### Custom Polygons

```julia
# Polygon from points (counterclockwise for outer boundary)
triangle = Polygon([
    Point(0μm, 0μm),
    Point(100μm, 0μm),
    Point(50μm, 86.6μm)
])

# L-shape
l_shape = Polygon([
    Point(0μm, 0μm),
    Point(100μm, 0μm),
    Point(100μm, 30μm),
    Point(30μm, 30μm),
    Point(30μm, 100μm),
    Point(0μm, 100μm)
])
```

## Polygons with Holes

```julia
# Create outer boundary
outer = [
    Point(0μm, 0μm),
    Point(100μm, 0μm),
    Point(100μm, 100μm),
    Point(0μm, 100μm)
]

# Create inner hole (clockwise for holes)
hole = [
    Point(30μm, 30μm),
    Point(30μm, 70μm),
    Point(70μm, 70μm),
    Point(70μm, 30μm)
]

# Using ClippedPolygon for polygons with holes
ring = ClippedPolygon([outer], [hole])
```

## Rendering Shapes

```julia
cell = Cell("shapes", nm)
render!(cell, centered_rect, GDSMeta(0))
render!(cell, circle, GDSMeta(1))
```

## See Also

- [Transform and Align](transform_and_align.md) - Moving and rotating shapes
- [Boolean Operations](boolean_operations.md) - Combining shapes
- [Shapes Reference](@ref) - Complete API
