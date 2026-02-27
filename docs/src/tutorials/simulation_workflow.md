# Tutorial: Simulation Workflow

This tutorial demonstrates how to go from a 2D layout to electromagnetic simulation using 3D solid models and meshes.

## What You'll Learn

- Creating solid models from coordinate systems
- Defining postrendering operations (extrusions, boolean ops)
- Generating meshes with Gmsh
- Controlling mesh quality
- Preparing configurations for Palace

## Prerequisites

- Completed [Schematic Basics](schematic_basics.md) tutorial
- Understanding of schematics and targets
- Optional: Palace installation for running simulations

## Overview

The simulation workflow extends the design flow from 2D layout to 3D:

```
CoordinateSystem → SolidModel → Mesh → Simulation
                       ↓
              (extrude, boolean ops)
```

Instead of rendering to a `Cell` for GDS output, we render to a [`SolidModel`](@ref) that creates 3D geometry suitable for finite element analysis. A `SolidModel` wraps [Gmsh](https://gmsh.info/) and uses the OpenCASCADE kernel for constructive solid geometry.

## Step 1: Create a Simple Device

Let's create a CPW resonator for simulation:

```julia
using DeviceLayout, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout

# Create a coordinate system for our device
cs = CoordinateSystem("resonator", nm)

# CPW meander
pa = Path(; name="resonator", metadata=SemanticMeta(:metal_negative))
straight!(pa, 500μm, Paths.CPW(10μm, 6μm))
turn!(pa, 180°, 50μm)
straight!(pa, 500μm)
turn!(pa, -180°, 50μm)
straight!(pa, 500μm)
terminate!(pa)

place!(cs, pa)

# Chip area (substrate boundary)
place!(cs, centered(Rectangle(2mm, 1mm)), SemanticMeta(:chip_area))

# Writeable area (where metal lives)
place!(cs, centered(Rectangle(1.8mm, 0.8mm)), SemanticMeta(:writeable_area))

# Simulation bounding box
place!(cs, centered(Rectangle(2.5mm, 1.5mm)), SemanticMeta(:simulated_area))
```

## Step 2: Define Z-Mapping

A z-map function tells the renderer where each layer sits in the third dimension. It takes entity metadata and returns a z-coordinate:

```julia
zmap = function(meta)
    layer_sym = layer(meta)
    if layer_sym == :chip_area
        return -525μm  # Substrate bottom
    elseif layer_sym == :simulated_area
        return -1000μm  # Simulation box bottom
    else
        return 0μm  # Default: substrate surface
    end
end
```

!!! tip "PDK approach"
    When using a [`ProcessTechnology`](@ref), the z-map is derived automatically from the technology's `height` parameters — see [`layer_height`](@ref). The manual approach shown here teaches what happens under the hood.

## Step 3: Define Postrendering Operations

Postrendering operations transform 2D geometry into 3D volumes. Each operation is a tuple of `(name, function, args, options...)`:

```julia
postrender_ops = [
    # Extrude substrate
    ("chip_area_extrusion", SolidModels.extrude_z!, ("chip_area", 525μm)),

    # Extrude simulation domain
    ("simulated_area_extrusion", SolidModels.extrude_z!, ("simulated_area", 2000μm)),

    # Create metal by subtracting negative from writeable area
    ("metal", SolidModels.difference_geom!,
        ("writeable_area", "metal_negative", 2, 2),
        :remove_object => true),

    # Create substrate volume (intersect with simulation domain)
    ("substrate", SolidModels.intersect_geom!,
        ("simulated_area_extrusion", "chip_area_extrusion", 3, 3),
        :remove_tool => true),

    # Create vacuum (simulation domain minus substrate)
    ("vacuum", SolidModels.difference_geom!,
        ("simulated_area_extrusion", "substrate", 3, 3),
        :remove_object => true),
]
```

## Step 4: Render to SolidModel

Create the 3D model and render:

```julia
sm = SolidModel("resonator_model", overwrite=true)

render!(sm, cs; zmap=zmap, postrender_ops=postrender_ops)
```

## Step 5: Generate the Mesh

Use Gmsh to create a finite element mesh:

```julia
# Set Gmsh options for mesh quality
SolidModels.gmsh.option.setNumber("Mesh.MeshSizeMin", 5.0)  # Min element size (μm)
SolidModels.gmsh.option.setNumber("Mesh.MeshSizeMax", 200.0)  # Max element size

# Generate 3D mesh
SolidModels.gmsh.model.mesh.generate(3)

# View the mesh (opens Gmsh GUI)
# SolidModels.gmsh.fltk.run()
```

## Step 6: Save the Mesh

Export the mesh in a format suitable for your solver:

```julia
using FileIO

# MSH v2 format (compatible with Palace)
save("resonator.msh2", sm)

# Or STEP format for CAD exchange
# save("resonator.stp", sm)
```

## Mesh Quality Control

DeviceLayout provides several ways to control mesh quality.

### Automatic Sizing

Entities carry mesh sizing information based on their geometry. Curved paths, for example, set mesh sizes at control points to resolve curvature automatically.

### MeshSized Style

Apply manual mesh control to specific entities with [`MeshSized`](@ref):

```julia
# Create a small feature that needs fine meshing
fine_feature = MeshSized(2μm, 1.5)(Rectangle(20μm, 20μm))
place!(cs, fine_feature, SemanticMeta(:metal_negative))
```

The first argument `h` sets the mesh size at the entity, and `α` controls how fast the mesh size grows away from it (see [`mesh_grading_default`](@ref) for the global default).

### Global Parameters

Control mesh parameters globally:

```julia
SolidModels.mesh_scale(0.5)  # Scale all mesh sizes by 0.5
SolidModels.mesh_order(2)     # Use second-order elements
```

## Working with Physical Groups

The solid model organizes geometry into "physical groups" that correspond to materials and boundaries:

```julia
# Get attributes dictionary (maps names to Gmsh tags)
attrs = SolidModels.attributes(sm)

# attrs["metal"] -> tag for metal surfaces
# attrs["substrate"] -> tag for substrate volume
# attrs["vacuum"] -> tag for vacuum volume
```

These attributes are used when defining boundary conditions and material properties in your simulation configuration.

## Creating a Palace Configuration

For electromagnetic simulation with [Palace](https://awslabs.github.io/palace/), create a configuration dictionary:

```julia
using JSON

attrs = SolidModels.attributes(sm)

config = Dict(
    "Problem" => Dict(
        "Type" => "Eigenmode",
        "Output" => "results/resonator"
    ),
    "Model" => Dict(
        "Mesh" => "resonator.msh2",
        "L0" => 1e-6  # Length scale in meters (μm default)
    ),
    "Domains" => Dict(
        "Materials" => [
            Dict(
                "Attributes" => [attrs["vacuum"]],
                "Permeability" => 1.0,
                "Permittivity" => 1.0
            ),
            Dict(
                "Attributes" => [attrs["substrate"]],
                "Permeability" => 1.0,
                "Permittivity" => 11.5  # Sapphire
            )
        ]
    ),
    "Boundaries" => Dict(
        "PEC" => Dict("Attributes" => [attrs["metal"]])
    ),
    "Solver" => Dict(
        "Order" => 2,
        "Eigenmode" => Dict("N" => 3, "Target" => 5.0)  # Find 3 modes near 5 GHz
    )
)

# Save configuration
open("config.json", "w") do f
    JSON.print(f, config, 2)
end
```

## Using SolidModelTarget with Schematics

The steps above build a solid model manually from a `CoordinateSystem`. When working with a schematic-driven design and a PDK, [`SolidModelTarget`](@ref) packages all of this — z-mapping, extrusions, and postrender operations — into a reusable target (see the [Creating a PDK](creating_a_pdk.md) tutorial for how to set one up):

```julia
# Given a PDK with a configured SolidModelTarget:
using MyPDK

g = SchematicGraph("my_device")
# ... add nodes, connect ...

sch = plan(g; log_dir=nothing)
check!(sch)

sm = SolidModel("device", overwrite=true)
render!(sm, sch, MyPDK.MY_SOLIDMODEL_TARGET)
```

The `SolidModelTarget` stores the technology's z-mapping (via [`layer_height`](@ref) and [`layer_thickness`](@ref)), bounding and substrate layer lists, and the postrender operations, so you don't need to specify them at each render call.

## Summary

In this tutorial, you learned:

- **SolidModel**: 3D geometry container using Gmsh/OpenCASCADE
- **z-mapping**: Placing layers at physical z-coordinates
- **Postrender operations**: Extrusions and boolean ops to build 3D volumes
- **Mesh generation**: Using Gmsh to create finite element meshes
- **Mesh control**: [`MeshSized`](@ref) for local refinement, [`mesh_scale`](@ref)/[`mesh_order`](@ref) for global settings
- **Physical groups**: Organizing geometry for simulation boundary conditions

## Next Steps

- Study the [SingleTransmon Example](../examples/singletransmon.md) for a complete simulation workflow
- Read about [Solid Modeling](@ref solid-modeling) for deeper understanding
- See the [SolidModels Reference](@ref) for complete API

## See Also

- [Palace documentation](https://awslabs.github.io/palace/) for simulation setup
- [Gmsh documentation](https://gmsh.info/doc/texinfo/gmsh.html) for mesh options
