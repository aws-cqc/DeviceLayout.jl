# How to Create Meshes

This guide shows how to generate finite element meshes for simulation.

## Basic Meshing

```julia
using DeviceLayout

# After rendering to SolidModel
SolidModels.gmsh.model.mesh.generate(3)  # 3D mesh
```

## Mesh Settings

```julia
# Set mesh size limits
SolidModels.gmsh.option.setNumber("Mesh.MeshSizeMin", 5.0)
SolidModels.gmsh.option.setNumber("Mesh.MeshSizeMax", 200.0)

# Element order
SolidModels.gmsh.option.setNumber("Mesh.ElementOrder", 2)
```

## View Mesh

```julia
# Open Gmsh GUI
SolidModels.gmsh.fltk.run()
```

## Save Mesh

```julia
using FileIO

# MSH v2 (Palace compatible)
save("model.msh2", sm)

# MSH v4
save("model.msh", sm)

# STEP (CAD exchange)
save("model.stp", sm)
```

## Finalize Gmsh

```julia
# Always finalize when done
SolidModels.gmsh.finalize()
```

## See Also

- [Generate Solid Models](generate_solid_model.md)
- [Add Mesh Sizing](../components/add_mesh_sizing.md)
