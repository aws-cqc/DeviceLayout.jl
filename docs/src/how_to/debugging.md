# How to Debug Common Issues

This guide helps troubleshoot common problems in DeviceLayout.jl.

## Schematic Planning Fails

**Problem**: `plan(g)` throws an error.

**Solutions**:
```julia
# Use strict=:no to skip problematic components
sch = plan(g; strict=:no)  # Logs errors, continues planning
```

Check for:
- Cyclic connections with inconsistent constraints
- Missing hook definitions
- Invalid hook names

## Rendering Fails

**Problem**: `render!(cell, sch, target)` throws an error.

**Solutions**:
```julia
# Skip problematic components
render!(cell, sch, target; strict=:no)
```

Check for:
- Invalid geometry (self-intersecting polygons)
- Missing layer mappings in target

## GDS Won't Save or Won't Load

**Problem**: Can't save to GDS file.

**Solutions**:
- Delete any existing file at target path
- Check file permissions
- Verify cell names are unique

## Gaps in GDS Output

**Problem**: ~1nm gaps between adjacent elements.

**Solutions**:
```julia
# Flatten before saving
flatten!(cell)
```

This avoids rounding errors from rotated cell references.

## Component Geometry Stale

**Problem**: Changed `_geometry!` but still seeing old geometry.

**Solutions**:
```julia
# Create new instance
comp = MyComponent() # Will have fresh geometry

# Or clear cached geometry
empty!(comp._geometry)
```

## Route Fails

**Problem**: `route!` can't find a valid path.

**Check**:
- Waypoints are reachable with the routing rule
- Endpoints have compatible directions
- Turn radii are achievable

## See Also

- [FAQ](../faq.md)
- [Schematic FAQ](../schematicdriven/faq.md)
