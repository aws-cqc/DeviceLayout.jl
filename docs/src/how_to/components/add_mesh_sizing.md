# How to Add Mesh Sizing

This guide shows how to control mesh density for simulation.

## Using MeshSized Style

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Apply mesh sizing to an entity
rect = Rectangle(50μm, 20μm)
meshed_rect = MeshSized(h=5μm, α=1.5)(rect)

place!(cs, meshed_rect, SemanticMeta(:metal))
```

Parameters:
- **h**: Target mesh size at this entity
- **α**: Grading factor (how fast size grows away from entity)

## In Component Geometry

```julia
function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, comp::MyComponent)
    # Fine mesh for small features
    fine_feature = MeshSized(h=2μm)(Rectangle(10μm, 5μm))
    place!(cs, fine_feature, :junction)
    
    # Coarse mesh for large areas
    coarse_area = MeshSized(h=50μm)(Rectangle(500μm, 500μm))
    place!(cs, coarse_area, :ground)
end
```

## Global Mesh Control

After rendering to a SolidModel:

```julia
# Scale all mesh sizes
SolidModels.mesh_scale(sm, 0.5)  # Finer mesh

# Set mesh element order
SolidModels.mesh_order(sm, 2)  # Second-order elements
```

## See Also

- [Tutorial: Simulation Workflow](../../tutorials/simulation_workflow.md)
- [SolidModels Reference](@ref)
