# How to Define Hooks

This guide shows how to define connection points (hooks) for components.

## Basic Hook Definition

```julia
using DeviceLayout, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout

function SchematicDrivenLayout.hooks(comp::MyComponent)
    # PointHook(position, direction_angle)
    p0 = PointHook(Point(0μm, 50μm), 180°)     # Left side, pointing left
    p1 = PointHook(Point(100μm, 50μm), 0°)     # Right side, pointing right
    
    return (; p0, p1)  # Named tuple
end
```

## Hook Directions

The direction angle points **into** the component:
- `0°`: Connections come from the right (+x)
- `90°`: Connections come from above (+y)
- `180°`: Connections come from the left (-x)
- `-90°` or `270°`: Connections come from below (-y)

## Multiple Hooks

```julia
function SchematicDrivenLayout.hooks(comp::StarComponent)
    center = Point(0μm, 0μm)
    radius = comp.arm_length
    
    return (;
        north = PointHook(center + Point(0μm, radius), -90°),
        south = PointHook(center - Point(0μm, radius), 90°),
        east = PointHook(center + Point(radius, 0μm), 180°),
        west = PointHook(center - Point(radius, 0μm), 0°),
    )
end
```

## Hook Arrays

```julia
function SchematicDrivenLayout.hooks(comp::MultiPortComponent)
    hooks_vec = [
        PointHook(Point(i * 50μm, 0μm), -90°) 
        for i in 1:comp.num_ports
    ]
    return (; ports = hooks_vec)  # Access as :ports[1], :ports[2], etc.
end
```

## See Also

- [Tutorial: Building a Component](../../tutorials/building_a_component.md)
- [Components Reference](@ref)
