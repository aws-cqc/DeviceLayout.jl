# How to Handle Path Intersections

This guide shows how to create crossovers when paths intersect.

## Automatic Intersection Detection

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Two crossing paths
p1 = Path(μm)
straight!(p1, 400μm, Paths.CPW(10μm, 6μm))

p2 = Path(Point(200μm, -100μm), α0=90°)
straight!(p2, 300μm, Paths.CPW(10μm, 6μm))

# Create air bridges at intersections
intersect!(
    Intersect.AirBridge(
        crossing_gap=5μm,
        foot_gap=3μm,
        foot_length=10μm,
        extent_gap=3μm,
        scaffold_gap=3μm,
        scaffold_meta=GDSMeta(2),
        air_bridge_meta=GDSMeta(3)
    ),
    p1, p2
)
```

## Self-Intersections

For spiral or meandering paths:

```julia
p = Path(μm)
# Create a spiral that crosses itself
for i in 1:5
    straight!(p, 100μm + i * 20μm, Paths.CPW(10μm, 6μm))
    turn!(p, 90°, 20μm)
end

intersect!(Intersect.AirBridge(...), p)  # Single path
```

## Render Result

```julia
cell = Cell("intersections", nm)
render!(cell, p1, GDSMeta(0))
render!(cell, p2, GDSMeta(1))
```

## See Also

- [Add Crossovers in Schematics](../schematics/add_crossovers.md)
- [Paths Reference](@ref)
