# How to Use Routing Strategies

This guide shows how to automatically route wires between components.

## Basic Routing

```julia
using DeviceLayout, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout

g = SchematicGraph("routed")
n1 = add_node!(g, Component1())
n2 = add_node!(g, Component2())

# Route between hooks
route!(g, 
    Paths.StraightAnd90(min_bend_radius=50μm),  # Routing rule
    n1 => :output, n2 => :input,                 # Endpoints
    Paths.CPW(10μm, 6μm),                        # Path style
    SemanticMeta(:metal_negative)                # Layer
)
```

## Routing Rules

```julia
# Manhattan routing (90° turns only)
rule90 = Paths.StraightAnd90(
    min_bend_radius=50μm,
    max_bend_radius=100μm
)

# 45° routing (allows diagonal segments)
rule45 = Paths.StraightAnd45(min_bend_radius=50μm)
```

## Waypoints

Guide routes through specific points:

```julia
route!(g, rule, n1 => :p1, n2 => :p0, style, meta;
    waypoints=[Point(1mm, 0.5mm), Point(2mm, 0.5mm)],
    global_waypoints=true  # Waypoints in global coordinates
)
```

## See Also

- [Connect Components](connect_components.md)
- [Add Crossovers](add_crossovers.md)
