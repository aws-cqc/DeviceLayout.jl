# [Solid Models](@id concept-solidmodels)

We can render geometry to a [3D model](./solidmodels.md). DeviceLayout.jl uses [Open CASCADE Technology](https://dev.opencascade.org/), an open-source 3D geometry library, through the API provided by [Gmsh](https://www.gmsh.info/doc/texinfo/gmsh.html), a 3D finite element mesh generator.

Starting with purely 2D geometry, we can generate a [`SolidModel`](@ref) by providing a map from layer name to position in the third dimension (`zmap`) as well as a list of Booleans, extrusions, and other operations to perform after rendering the 2D entities (`postrender_ops`).

It's not really recommended to do this directly from geometry-level layout. There are tools in the schematic-driven layout interface that handle some of the complexity for you (see [`SchematicDrivenLayout.SolidModelTarget`](@ref)). Making out-of-plane "crossovers" can also be a bit involved, so there's a helper method [`SolidModels.staple_bridge_postrendering`](@ref) to generate the postrendering operations for a basic "staple" configuration.

The 2D-to-3D pipeline is one reason to work with "native" geometry in a `CoordinateSystem`, rather than discretizing everything into `Polygon`s as we would for a `Cell`. When we render curved Paths and rounded shapes to a `SolidModel`, circular arcs in paths and rounded corners are represented as exact circular arcs, and arbitrary curves are approximated with cubic B-splines. This not only keeps model size down but also allows Gmsh to make better meshes.

Moreover, when DeviceLayout.jl renders path segments and certain other entities, it automatically sets mesh sizing information to help Gmsh make better meshes. You can also annotate entities with the [MeshSized](@ref) style to provide such information manually.

See [API Reference: SolidModels](@ref api-solidmodels).

## What is a SolidModel?

A [`SolidModel`](@ref) wraps the Gmsh meshing library, managing a named Gmsh model together with a collection of **physical groups** that organize entities by name and dimension. Internally it holds four dictionaries of physical groups -- one per geometric dimension (0 through 3) -- plus a reference to the geometry kernel.

The default Open CASCADE kernel is the right choice for virtually all simulation workflows. It provides exact B-Rep geometry, Boolean operations, and conformal fragmentation. There is also some support for the "native" Gmsh kernel, which can be useful for simple meshes but cannot perform the Boolean operations essential for building a valid simulation model.

## Physical groups

Physical groups are the central abstraction connecting geometry to simulation. A **physical group** is a named collection of geometric entities at a single dimension.

When rendering to a `SolidModel`, entity metadata creates physical groups whose names default to the original layer names as strings. You generally work with physical groups rather than individual entities in the 3D interface.

When a simulation solver like Palace reads the exported mesh, it uses physical group names to assign material properties, boundary conditions, and excitation ports. The [`attributes`](@ref SolidModels.attributes) function builds a dictionary mapping group names to integer tags for solver configuration files.

You will generally work with physical groups rather than individual entities in the 3D geometry interface, using "postrendering" operations to build up new physical groups that correspond to materials and boundaries.

## The 2D-to-3D pipeline

Rendering a design to a `SolidModel` follows the general [rendering pattern](@ref concept-rendering) with extra "postrendering" steps for the third dimension. The five stages are:

```
flatten --> to_primitives --> physical groups --> postrender ops --> fragment & cleanup
```

### 1. Flatten

`flatten(cs)` collapses the coordinate-system hierarchy into a single list of positioned elements with their metadata, resolving all `StructureReference` transformations into global coordinates.

### 2. Primitive dispatch

Each element is converted to kernel-native geometry via `to_primitives(sm, entity)`. OpenCascade represents curves and ellipses as exact geometry. Exact arcs produce smoother meshes with fewer elements—see the example [here](./geometry.md#Solid-Models).

### 3. Physical group creation

Rendered entities are grouped by their mapped layer name. The `map_meta` function controls this mapping; when rendering through a `SolidModelTarget`, it applies rules for levelwise layers (appending `_L1`, `_L2`, etc.) and indexed layers (appending `_1`, `_2`, etc.). At this stage, entities also receive mesh sizing information from [`MeshSized`](@ref) metadata.

### 4. Postrender operations

After all 2D geometry is placed at its z-height, a sequence of **postrender operations** transforms flat surfaces into a complete 3D model. These operations are specified as a list of tuples:

```julia
(destination_name, operation, (args...), kwargs...)
```

The recommended pattern is to provide all postrendering operations to the `postrender_ops` keyword argument or `SolidModelTarget` in `render!`, because `render!` performs important cleanup at the very end. Specifically, it removes duplicate elements using the `fragment` operation; because this can also change the labeling of elements, it then reassigns the resulting elements to their corresponding groups.

### 5. Fragment and cleanup

The final stage ensures a **conformal mesh** where every mesh element belongs to exactly one material region and neighboring regions share faces. `render!` calls `_fragment_and_map!` twice: first on dimensions `[1, 0]` (curves and points), then on `[1, 2, 3]` (curves, surfaces, and volumes). The fragment operation splits all overlapping entities at their shared boundaries and reassigns the resulting pieces back to their original physical groups. After fragmentation, `render!` installs a mesh sizing callback and optionally removes physical groups not listed in `retained_physical_groups`.

### [SolidModelTarget and schematic-driven rendering](@id concept-solidmodeltarget)

For most users, solid modeling happens through the schematic-driven workflow rather than by calling `render!` on a `CoordinateSystem` directly. [`SolidModelTarget`](@ref SchematicDrivenLayout.SolidModelTarget) orchestrates the entire 2D-to-3D conversion:

```julia
target = SolidModelTarget(
    technology;
    bounding_layers = [:simulated_area],
    levelwise_layers = [:metal_negative],
    indexed_layers = [],
    substrate_layers = [:chip_area],
    postrender_ops = custom_ops
)
sm = SolidModel("model")
render!(sm, schematic, target)
```

**Metadata mapping:** `SolidModelTarget` controls how element metadata maps to physical group names. Entities with the `:norender` layer or layers in `ignored_layers` are skipped. The base group name comes from `layername(meta)`. Levelwise layers get `"_L$(level)"` appended; indexed layers get `"_$(index)"` appended when the index is nonzero.

**Automatic extrusion:** Extrusion heights come from the `ProcessTechnology` associated with the target. The `thickness` parameter maps each layer symbol to a thickness (or a per-level vector of thicknesses). Layers in `substrate_layers` extrude downward; all others extrude upward from their z-height. Levelwise layers are an exception, as explained below.

**Flipchip handling**: `SolidModelTarget` can be used to apply a specific interpretation of `level` in `SemanticMeta`. The level of a geometric entity describes the vertical index of its substrate surface in a "flipchip"-style stack of substrates. Metadata types without a
level attribute will default to level 1.

```
▒    ...        ▒
▒   level 3 ↓   ▒
█████████████████
▒   level 2 ↑   ▒
▒               ▒
▒   level 1 ↓   ▒
█████████████████
▒   level 0 ↑   ▒
```

The "substrate surface" z-height for a given `SemanticMeta` is calculated based on its level together with technology `chip_thicknesses` and `flipchip_gaps`. For non-levelwise layers, height and thickness are always measured along the global positive z axis, as explained above. For layers in `levelwise_layers`, positive height or extrusion thickness is always away from the substrate.

## Meshing

Entities can carry mesh sizing information with them when rendered to a `SolidModel`. Many
entities will default to a maximal size to reasonably resolve the geometry. This is
particularly useful together with adaptive mesh refinement to efficiently refine your mesh
to minimize estimated error with as few elements as possible. You can also style entities
with [`MeshSized`](@ref) to manually control mesh sizing, the [`SolidModels.mesh_scale`](@ref),
[`SolidModels.mesh_order`](@ref) and [`SolidModels.mesh_grading_default`](@ref) methods are used to modify the
global default parameters used in each sizing field (see [`MeshSized`](@ref)).

Size fields within a `SolidModel` are specified in terms of control points, which are
spatial locations combined with an `(h, α)` as in [`MeshSized`](@ref). When a model is
rendered, a set of control points are computed from the geometry, and these are then used to
create `KDTree` structures to allow for rapid evaluation. Additional points can be manually
inserted after `render!` is called using [`DeviceLayout.SolidModels.add_mesh_size_point`](@ref), and the global size parameters
[`SolidModels.mesh_scale`](@ref), [`SolidModels.mesh_order`](@ref) and [`SolidModels.mesh_grading_default`](@ref) modified without requiring `render!`
to be called again. This allows for iteration on the mesh for a given fixed geometry. Manual
modification of the control points is in general not necessary but can be achieved through
[`DeviceLayout.SolidModels.add_mesh_size_point`](@ref), [`DeviceLayout.SolidModels.finalize_size_fields!`](@ref),
[`DeviceLayout.SolidModels.clear_mesh_control_points!`](@ref) and
[`DeviceLayout.SolidModels.reset_mesh_control!`](@ref). Once an improved mesh has been
achieved through addition of custom size fields like this, it is generally suggested to
incorporate this information back into the `MeshSized` style used on the original entities.

!!! info
    
    If [`SolidModels.mesh_control_points`](@ref) is modified, then it is important to call
    [`SolidModels.finalize_size_fields!`](@ref) in order to ensure that the `KDTree` are rebuilt.
    Additionally, to generate a new mesh `SolidModels.gmsh.model.mesh.clear()` must be called
    otherwise `gmsh` will return only any previously generated mesh.

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

## Integration with Palace

Physical groups are the interface between DeviceLayout.jl and electromagnetic solvers. In a Palace simulation workflow:

1. Physical group **names** identify material regions, boundary surfaces, and excitation ports.
2. Physical group **integer tags** become the "attribute" numbers referenced in Palace's JSON configuration file.
3. The [`attributes`](@ref SolidModels.attributes) function builds the name-to-tag mapping needed for configuration generation.

For a complete worked example, see the [Single Transmon tutorial](@ref single-transmon-example).

## See also

- [Concepts: Geometry](@ref geometry-concepts) and [Concepts: rendering](@ref concept-rendering), which focus on 2D geometry but have content relevant to 3D
- [Solid Models API reference](@ref api-solidmodels)