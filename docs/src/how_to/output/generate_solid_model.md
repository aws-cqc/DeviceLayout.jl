# How to Generate Solid Models

This guide shows how to create 3D models for electromagnetic simulation.

## Basic Solid Model

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

sm = SolidModel("model", overwrite=true)

# Render coordinate system to solid model
render!(sm, cs;
    zmap = meta -> 0μm,  # z-height for each layer
    postrender_ops = []   # 3D operations
)
```

## Z-Mapping

```julia
zmap = function(meta)
    layer_name = layer(meta)
    if layer_name == :chip_area
        return -525μm
    elseif layer_name == :simulated_area
        return -1000μm
    else
        return 0μm
    end
end
```

## Postrender Operations

```julia
postrender_ops = [
    # Extrude
    ("substrate", SolidModels.extrude_z!, ("chip_area", 525μm)),
    
    # Boolean difference
    ("metal", SolidModels.difference_geom!, 
        ("writeable_area", "metal_negative")),
]
```

## From Schematic

```julia
sm = SolidModel("device", overwrite=true)
render!(sm, schematic, solid_model_target)
```

## Save Model

```julia
using FileIO
save("model.stp", sm)  # STEP format
save("model.msh2", sm)  # Gmsh mesh
```

## See Also

- [Create Meshes](create_mesh.md)
- [Tutorial: Simulation Workflow](../../tutorials/simulation_workflow.md)
