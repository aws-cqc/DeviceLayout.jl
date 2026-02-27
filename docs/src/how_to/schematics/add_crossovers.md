# How to Add Crossovers

This guide shows how to automatically create crossovers where paths intersect.

## Schematic-Level Crossovers

```julia
using DeviceLayout.SchematicDrivenLayout

# After planning the schematic
sch = plan(g)

# Define crossover style
xstyle = Intersect.AirBridge(
    crossing_gap=5μm,
    foot_gap=3μm,
    foot_length=10μm,
    extent_gap=3μm,
    scaffold_gap=3μm,
    scaffold_meta=SemanticMeta(:bridge_base),
    air_bridge_meta=SemanticMeta(:bridge)
)

# Generate crossovers for all intersecting paths
crossovers!(sch, xstyle)
```

## Selective Crossovers

```julia
# Only check specific nodes
crossovers!(sch, xstyle, [route_node1, route_node2])
```

## Crossover Order

By default:
- Routes cross over explicit paths
- Later-added components cross over earlier ones

## See Also

- [Handle Path Intersections](../paths/handle_intersections.md)
- [Schematics Reference](@ref)
