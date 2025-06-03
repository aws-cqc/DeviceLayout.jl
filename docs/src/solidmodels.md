# Solid Models

```@docs
    SolidModel
    SolidModels.SolidModelKernel
    SolidModels.attributes
```

## Physical groups

```@docs
    SolidModels.PhysicalGroup
    SolidModels.dimtags
    SolidModels.entitytags
    SolidModels.bounds3d
```

## Rendering to a SolidModel

```@docs
    render!(::SolidModel, ::CoordinateSystem; kwargs...)
    SolidModels.to_primitives
```

### Postrendering operations

After adding the elements of a `CoordinateSystem` to a `SolidModel` ("rendering"), we can
perform additional "postrendering" operations including boolean operations, extrusions, and
selections, to create new `PhysicalGroup`s.

The recommended pattern is to provide all postrendering operations to the `postrender_ops`
keyword argument in `render!`, because `render!` performs important cleanup at the very end.
Specifically, it removes duplicate elements using the `fragment` operation; because
this can also change the labeling of elements, it then reassigns the resulting elements to
their corresponding groups.

Boolean operations and infix equivalents:

```@docs
    SolidModels.difference_geom!
    SolidModels.fragment_geom!
    SolidModels.intersect_geom!
    SolidModels.union_geom!
    SolidModels.:+(::SolidModels.AbstractPhysicalGroup, ::SolidModels.AbstractPhysicalGroup)
    SolidModels.:∪(::SolidModels.AbstractPhysicalGroup, ::SolidModels.AbstractPhysicalGroup)
    SolidModels.:-(::SolidModels.AbstractPhysicalGroup, ::SolidModels.AbstractPhysicalGroup)
    SolidModels.:*(::SolidModels.AbstractPhysicalGroup, ::SolidModels.AbstractPhysicalGroup)
    SolidModels.:∩(::SolidModels.AbstractPhysicalGroup, ::SolidModels.AbstractPhysicalGroup)
```

Selections:

```@docs
    SolidModels.box_selection
    SolidModels.get_boundary
```

Other operations:

```@docs
    SolidModels.extrude_z!
    SolidModels.remove_group!
    SolidModels.restrict_to_volume!
    SolidModels.revolve!
    SolidModels.set_periodic!
    SolidModels.translate!
```

### Meshing

Entities can carry mesh sizing information with them when rendered to a `SolidModel`. Many entities will default to a maximal size to reasonably resolve the geometry. This is particularly useful together with adaptive mesh refinement to efficiently refine your mesh to minimize estimated error with as few elements as possible. You can also style entities with [`MeshSized`](@ref) to manually control mesh sizing, and provide `MeshingParameters` to `render!` using the `meshing_parameters` keyword argument.

```@docs
    SolidModels.MeshingParameters
```

## Example

Below, we create a 3D model of a meandered CPW on a chip, restricting the model to a small
volume (for example, for the purposes of simulation).

```julia
using DeviceLayout
using FileIO

cs = CoordinateSystem("test", nm)

# Create a CPW meander
pa = Path(-0.5mm, 0nm)
straight!(pa, 900μm, Paths.SimpleCPW(10μm, 6μm))
turn!(pa, 180°, 50μm)
straight!(pa, 900μm)
turn!(pa, -180°, 50μm)
straight!(pa, 900μm)
turn!(pa, 180°, 50μm)
straight!(pa, 900μm)
terminate!(pa)
render!(cs, pa, SemanticMeta(:base_negative))

render!(cs, centered(Rectangle(10mm, 10mm)), SemanticMeta(:chip_area))
render!(cs, centered(Rectangle(9mm, 9mm)), SemanticMeta(:writeable_area))
render!(cs, centered(Rectangle(2mm, 2mm)), SemanticMeta(:simulated_area))

# Define z heights and thickness (where nonzero)
layer_z = Dict(:chip_area => -525μm, :simulated_area => -1mm)
layer_thickness = Dict(:chip_area => 525μm, :simulated_area => 2mm)

# Define postrendering operations:
# Extrusions, geometric Boolean operations, and other transformations
postrender_ops = vcat(
    [   # Extrude layers with nonzero thickness
        (string(layer) * "_extrusion", SolidModels.extrude_z!, (layer, thickness)) for
        (layer, thickness) in pairs(layer_thickness)
    ],
    [   # sm["chip_sim"] = intersect_geom!(sm, "simulated_area_extrusion", ...)
        (   # Intersect chip volume with simulation volume
            "chip_sim", # New physical group name
            SolidModels.intersect_geom!, # Operation
            # Arguments: Object, tool, object dimension, tool dimension
            ("simulated_area_extrusion", "chip_area_extrusion", 3, 3), # Vol ∩ Vol
            # Keyword arguments
            :remove_tool => true # Remove the "chip_area_extrusion" group
        ),
        (   # Intersect writeable area with simulation volume
            "writeable_sim",
            SolidModels.intersect_geom!,
            ("simulated_area_extrusion", "writeable_area", 3, 2), # Volume ∩ Area
            :remove_tool => true # Remove "writeable_area" group
        ),
        (   # Create group for non-chip volumes (vacuum)
            "vac_sim",
            SolidModels.difference_geom!, # Subtract "tool" from "object"
            ("simulated_area_extrusion", "chip_sim", 3, 3),
            :remove_object => true # Remove "simulated_area_extrusion" group
        ),
        (   # Subtract negative from writeable area to get metal area
            "base_metal",
            SolidModels.difference_geom!,
            ("writeable_sim", "base_negative"), # Uses default dimension 2
            :remove_object => true # Remove "writeable_sim" group
        )
    ]
)

sm = SolidModel("model"; overwrite=true)
SolidModels.render!(
    sm,
    cs,
    zmap=(m) -> get(layer_z, layer(m), 0μm),
    postrender_ops=postrender_ops
)
SolidModels.gmsh.model.mesh.generate() # Generate default mesh (low quality)
save("model.msh2", sm) # Use older MSH v2 format (Gmsh format compatible with Palace)
# save("model.stp", sm) # Use standard STEP format
SolidModels.gmsh.finalize() # Finalize the Gmsh API when done using Gmsh
```
