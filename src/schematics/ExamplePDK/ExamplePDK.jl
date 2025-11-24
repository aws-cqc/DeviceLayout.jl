"""
    module ExamplePDK

An example Process Design Kit (PDK) containing process technology information, components,
and rendering targets.

`ExamplePDK` is intended for demonstrations, tutorials, and tests. While we aim to
demonstrate best practices for Julia code and DeviceLayout.jl usage, these components are not
optimized for device performance. Most importantly: **Breaking changes to `ExamplePDK` may
occur within major versions.** In other words, don't depend on `ExamplePDK` in your own PDK
or for real devices!
"""
module ExamplePDK

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits

##### Layers
"""
    const LAYER_RECORD

A `NamedTuple` mapping semantic layer name `Symbol`s to GDS layer and datatype.

Process layers:

    metal_positive   = GDSMeta(1, 1)
    metal_negative   = GDSMeta(1, 2)
    dielectric       = GDSMeta(2, 0)
    marker           = GDSMeta(3, 0)
    junction_pattern = GDSMeta(10, 0)
    bridge_base      = GDSMeta(20, 0)
    bridge           = GDSMeta(21, 0)
    bump             = GDSMeta(30, 0)

Informational layers:

    chip_area      = GDSMeta(100, 0)
    writeable_area = GDSMeta(101, 0)
    annotation     = GDSMeta(102, 0)

Simulation layers:

    simulated_area = GDSMeta(200, 0)
    port           = GDSMeta(210, 0)
    lumped_element = GDSMeta(211, 0)
    mesh_control   = GDSMeta(220, 0)
    integration    = GDSMeta(230, 0)

See also [`ExamplePDK.LayerVocabulary`](@ref)
"""
const LAYER_RECORD = (;
    # Process layers
    metal_positive   = GDSMeta(1, 1),
    metal_negative   = GDSMeta(1, 2),
    dielectric       = GDSMeta(2, 0),
    marker           = GDSMeta(3, 0),
    junction_pattern = GDSMeta(10, 0),
    bridge_base      = GDSMeta(20, 0),
    bridge           = GDSMeta(21, 0),
    bump             = GDSMeta(30, 0),

    # Informational layers
    chip_area      = GDSMeta(100, 0),
    writeable_area = GDSMeta(101, 0), # e.g., for metal = (writable_area - metal_negative) + metal_positive
    annotation     = GDSMeta(102, 0),

    # Simulation layers
    simulated_area = GDSMeta(200, 0),
    port           = GDSMeta(210, 0),
    lumped_element = GDSMeta(211, 0),
    wave_port      = GDSMeta(212, 0),
    mesh_control   = GDSMeta(220, 0),
    integration    = GDSMeta(230, 0)
)

"""
    module LayerVocabulary

Exports constants for each layer name in `ExamplePDK.LAYER_RECORD`.

For example, defines `const METAL_NEGATIVE = SemanticMeta(:metal_negative)`, then exports
it so that `using LayerVocabulary` brings `METAL_NEGATIVE` into the namespace.
"""
module LayerVocabulary
# Module that exports `LAYER_NAME = SemanticMeta(:layer_name)` for each layer in `LAYER_RECORD`
import ..ExamplePDK: LAYER_RECORD, SemanticMeta
_vocabulary_const_symbol(layer::Symbol) = Symbol(uppercase(string(layer)))
for layer in keys(LAYER_RECORD)
    const_sym = _vocabulary_const_symbol(layer)
    meta = SemanticMeta(layer)
    @eval const $const_sym = $meta # e.g., const METAL_NEGATIVE = SemanticMeta(:metal_negative)
    @eval export $const_sym # e.g., export METAL_NEGATIVE
    import ..DeviceLayout.NORENDER_META
    export NORENDER_META
end
end # LayerVocabulary

##### Process technologies
"""
    const EXAMPLE_FLIPCHIP_TECHNOLOGY::ProcessTechnology

A `ProcessTechnology` combining the `ExamplePDK` layer record with process parameters for flipchip assembly.
"""
const EXAMPLE_FLIPCHIP_TECHNOLOGY = ProcessTechnology(
    LAYER_RECORD,
    (;  # Use unrealistic thicknesses for the sake of clearer visualizations
        chip_thicknesses=[100μm, 100μm], # [Bottom chip, top chip] (for calculating z height by level)
        flipchip_gaps=[80μm], # Space between chip surfaces (for calculating z height by level)
        height=(; # z height at the bottom
            simulated_area=-1mm,
            wave_port=[-160μm, -160μm]
        ),
        thickness=(; # Extrusion distances for various layers
            simulated_area=2mm,
            chip_area=[100μm, 100μm], # For levelwise layers, specify thickness for each level
            wave_port=[400μm, 400μm],
            bump=80μm
        )
    )
)
"""
    const EXAMPLE_SINGLECHIP_TECHNOLOGY::ProcessTechnology

A `ProcessTechnology` combining the `ExamplePDK` layer record with process parameters for
single chip assembly.
"""
const EXAMPLE_SINGLECHIP_TECHNOLOGY = ProcessTechnology(
    LAYER_RECORD,
    (;
        height=(; # z height at the bottom
            simulated_area=-1mm,
            wave_port=-200μm
        ),
        thickness=(; # Extrusion distances for various layers
            simulated_area=2mm,
            chip_area=525μm,
            wave_port=400μm
        )
    )
)

##### Rendering targets
# Target that only renders level 1
const L1_TARGET = ArtworkTarget(EXAMPLE_FLIPCHIP_TECHNOLOGY, levels=[1])
# Target that only renders level 2 (will need to be flipped to orient face up)
const L2_TARGET = ArtworkTarget(EXAMPLE_FLIPCHIP_TECHNOLOGY, levels=[2])
# For visualizing a two-level assembly
const ASSEMBLY_TARGET = ArtworkTarget(EXAMPLE_FLIPCHIP_TECHNOLOGY, levels=[1, 2])
# If L1 and L2 had different layer records, we could manually populate the map_meta_dict
# for (layer, meta) in pairs(layer_record(L2_TECHNOLOGY))
#     meta isa GDSMeta && (meta = GDSMeta(meta.layer + 300, meta.datatype))
#     ASSEMBLY_TARGET.map_meta_dict[facing(SemanticMeta(layer))] = meta
# end

# For building SolidModels for simulation
"""
    const SINGLECHIP_SOLIDMODEL_TARGET::SolidModelTarget

A `Target` for rendering to a `SolidModel` using the `ExamplePDK`'s process technology.

Contains rendering options and postrendering operations to create a solid model suitable
for simulation of a single-chip device (as opposed to a flipchip device).
"""
const SINGLECHIP_SOLIDMODEL_TARGET = SolidModelTarget(
    EXAMPLE_SINGLECHIP_TECHNOLOGY; # Thickness and height define z-height and extrusions
    simulation=true, # Optional simulation-only geometry entities will be rendered
    bounding_layers=[:simulated_area], # SIMULATED_AREA defines the simulation bounds
    substrate_layers=[:chip_area], # CHIP_AREA will be extruded downward
    indexed_layers=[:port, :lumped_element, :integration, :wave_port], # Automatically index these layers
    wave_port_layers=[:wave_port], # WAVE_PORT are 1D line segments in x-y to be extruded in z
    postrender_ops=[ # Manual definition of operations to run after 2D rendering
        (   # Unify metal negative before removing from writeable_area
            "metal_negative", # Output group name
            SolidModels.union_geom!, # Operation
            ("metal_negative", "metal_negative", 2, 2), # (object, tool, object_dim, tool_dim)
            :remove_object => true # Remove "metal_negative" entities after operation
        ),
        (   # Get metal ground plane by subtracting negative from writeable area
            "metal", # Output group name
            SolidModels.difference_geom!, # Operation
            ("writeable_area", "metal_negative", 2, 2), # (object, tool, object_dim, tool_dim)
            :remove_object => true # Remove "writeable_area" group after operation
        ),
        (   # Then add any positive back in
            "metal",
            SolidModels.union_geom!,
            ("metal", "metal_positive", 2, 2),
            :remove_tool => true
        ),
        (   # Define a bulk physical group for all the substrates in the domain.
            "substrate",
            SolidModels.union_geom!,
            ("chip_area_extrusion", "chip_area_extrusion", 3, 3),
            :remove_object => true,
            :remove_tool => true
        ),
        (   # Define the vacuum domain as the remainder of the simulation domain.
            "vacuum",
            SolidModels.difference_geom!,
            ("simulated_area_extrusion", "substrate", 3, 3)
        ),
        # Generate staple bridges in "bridge_metal" group
        SolidModels.staple_bridge_postrendering(;
            base="bridge_base",
            bridge="bridge",
            bridge_height=10μm # Exaggerated, for visualization
        )...,
        (   # Union of all physical metal
            "metal",
            SolidModels.union_geom!,
            ("metal", "bridge_metal"),
            :remove_object => true,
            :remove_tool => true
        ),
        (("metal", SolidModels.difference_geom!,
            ("metal", "port"), :remove_object => true))
    ],
    # We only want to retain physical groups that we will need for specifying boundary
    # conditions in the physical domain.
    retained_physical_groups=[
        ("vacuum", 3),
        ("substrate", 3),
        ("metal", 2),
        ("exterior_boundary", 2)
    ]
)

"""
    singlechip_solidmodel_target(boundary_groups)

Helper function for creating a SolidModelTarget for a single chip, with additional boundary
groups to be retained specified by boundary_groups
"""
function singlechip_solidmodel_target(boundary_groups...)
    target = deepcopy(SINGLECHIP_SOLIDMODEL_TARGET)
    push!(
        target.postrenderer,
        ("metal", SolidModels.difference_geom!, ("metal", [boundary_groups...]), :remove_object=>true)
    )
    retained_physical_groups = [(x, 2) for x ∈ boundary_groups]
    append!(target.rendering_options.retained_physical_groups, retained_physical_groups)
    return target
end
singlechip_solidmodel_target(boundary_groups::Vector) =
    singlechip_solidmodel_target(boundary_groups...)

"""
    const FLIPCHIP_SOLIDMODEL_TARGET::SolidModelTarget

A `Target` for rendering to a `SolidModel` using the `ExamplePDK`'s process technology.

Contains rendering options and postrendering operations to create a solid model suitable
for simulation of a flipchip device.
"""
const FLIPCHIP_SOLIDMODEL_TARGET = SolidModelTarget(
    EXAMPLE_FLIPCHIP_TECHNOLOGY;
    simulation=true,
    bounding_layers=[:simulated_area],
    substrate_layers=[:chip_area],
    levelwise_layers=[
        :writeable_area, # Need separate L1/L2 for metal booleans
        :metal_negative,
        :metal_positive,
        :chip_area, # and for chip and bridge extrusion in opposite directions by layer
        :bridge_base,
        :bridge,
        :wave_port
    ],
    indexed_layers=[:port, :lumped_element, :integration, :wave_port],
    wave_port_layers=[:wave_port],
    postrender_ops=[
        (   # Get metal ground plane by subtracting negative from writeable area
            "metal_L1",
            SolidModels.difference_geom!,
            ("writeable_area_L1", "metal_negative_L1", 2, 2),
            :remove_object => true
        ),
        (   # Then add any positive back in
            "metal_L1",
            SolidModels.union_geom!,
            ("metal_L1", "metal_positive_L1", 2, 2),
            :remove_tool => true
        ),
        (   # Same thing on L2
            "metal_L2",
            SolidModels.difference_geom!,
            ("writeable_area_L2", "metal_negative_L2", 2, 2),
            :remove_object => true
        ),
        (
            "metal_L2",
            SolidModels.union_geom!,
            ("metal_L2", "metal_positive_L2", 2, 2),
            :remove_tool => true
        ),
        (   # Define a bulk physical group for all the substrates in the domain.
            "substrates",
            SolidModels.union_geom!,
            ("chip_area_L1_extrusion", "chip_area_L2_extrusion", 3, 3),
            :remove_object => true,
            :remove_tool => true
        ),
        (   # Define the vacuum domain as the remainder of the simulation domain.
            "vacuum",
            SolidModels.difference_geom!,
            ("simulated_area_extrusion", "substrates", 3, 3)
        ),
        ("vacuum", SolidModels.difference_geom!, ("vacuum", "bump_extrusion", 3, 3)),
        # Generate staple bridges in "bridge_metal" group
        SolidModels.staple_bridge_postrendering(;
            levels=[1, 2],
            base="bridge_base",
            bridge="bridge",
            bridge_height=10μm # Exaggerated, for visualization
        )...,
        (   # The "bump" group is extruded because "bump" was specified in thickness, we only care about the exterior.
            "bump_surface",
            SolidModels.get_boundary,
            ("bump_extrusion", 3),
            :oriented => false
        ),
        (   # Union of all physical metal
            "metal",
            SolidModels.union_geom!,
            (["metal_L1", "metal_L2", "bridge_metal", "bump_surface"], 2),
            :remove_object => true, :remove_tool => true
        ),
        ("metal", SolidModels.difference_geom!, ("metal", "port"), :remove_object => true)
    ],
    # We only want to retain physical groups that we will need for specifying boundary
    # conditions in the physical domain.
    retained_physical_groups=[
        ("vacuum", 3),
        ("substrates", 3),
        ("metal", 2),
        ("exterior_boundary", 2)
    ]
)

"""
    flipchip_solidmodel_target(boundary_groups)

Helper function for creating a SolidModelTarget for a single chip, with additional boundary
groups to be retained specified by boundary_groups
"""
function flipchip_solidmodel_target(boundary_groups...)
    target = deepcopy(FLIPCHIP_SOLIDMODEL_TARGET)
    retained_physical_groups = [(x, 2) for x ∈ boundary_groups]
    append!(target.rendering_options.retained_physical_groups, retained_physical_groups)
    return target
end
flipchip_solidmodel_target(boundary_groups::Vector) =
    flipchip_solidmodel_target(boundary_groups...)

const COMPONENTS_DIR = joinpath(dirname(@__DIR__), "components")

include("utils.jl")
# For convenient testing and tutorials, ExamplePDK is just a SchematicDrivenLayout
# submodule, and component modules are defined as submodules within ExamplePDK by including
# their source files.
include("components/ChipTemplates/ChipTemplates.jl")
include("components/SimpleJunctions/SimpleJunctions.jl")
include("components/Transmons/Transmons.jl")
include("components/ClawCapacitors/ClawCapacitors.jl")
include("components/ReadoutResonators/ReadoutResonators.jl")
# When you create your own PDK, we recommend making separate packages for independent components,
# each of which has your PDK package as a dependency and uses its layer vocabulary.
# That way, you can add, edit, and version technologies and components independently.
# The files can be organized in a similar way, as separate packages within a single repository,
# registered to your private Julia package registry.
# Each subfolder in `/components/` would represent its own package (e.g., MyTransmons.jl)
# with its own `Project.toml` specifying a version number, dependencies, and compatibility
# requirements.

end # module
