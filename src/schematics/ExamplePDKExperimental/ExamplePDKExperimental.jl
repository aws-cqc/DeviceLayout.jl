"""
    module ExamplePDKExperimental

A version of [`ExamplePDK`](@ref SchematicDrivenLayout.ExamplePDK) for the experimental
[`SolidModelsExperimental`](@ref solidmodels-experimental-api) pipeline, containing the
components needed for a single-transmon simulation.

Geometry is placed on layers with [`LayerRef`](@ref
DeviceLayout.SolidModelsExperimental.LayerRef) instead of `SemanticMeta`, and components
carry locators that select their ports and terminals in the rendered model.

`ExamplePDKExperimental` is intended for demonstrations, tutorials, and tests. **Breaking
changes may occur within major versions.** Don't depend on it in your own PDK or for real
devices!
"""
module ExamplePDKExperimental

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
using DeviceLayout.SolidModelsExperimental:
    Cut,
    DIELECTRIC,
    Extrude,
    Fuse,
    GetBoundary,
    LayerRef,
    METAL,
    NULL,
    Remove,
    RestrictTo,
    SolidModelTarget,
    SourceLayer,
    SourceStack,
    Translate
import DeviceLayout.SolidModelsExperimental

"""
    const SINGLECHIP_STACK::SourceStack

The source layers of a single-chip device, with the GDS layers of `ExamplePDK`.

`:metal` is the writeable area, from which the target subtracts `:metal_negative` and to
which it adds the `:junction_leads`. `:substrate` extends 525μm below the chip surface, inside
a 2mm-tall `:simulated_area`.

Layers used only in the solid model, such as `:junction_leads` and the port layers, have no
GDS layer; `:junction_pattern` is artwork only.
"""
const SINGLECHIP_STACK = SourceStack(
    :metal => SourceLayer(METAL; gds_meta=GDSMeta(101, 0)),
    :metal_negative => SourceLayer(NULL; gds_meta=GDSMeta(1, 2)),
    :junction_leads => SourceLayer(METAL; gds_meta=nothing),
    :junction_pattern => SourceLayer(NULL; gds_meta=GDSMeta(10, 0), solidmodel=false),
    :bridge_base => SourceLayer(METAL; gds_meta=GDSMeta(20, 0)),
    :bridge => SourceLayer(METAL; gds_meta=GDSMeta(21, 0)),
    :substrate => SourceLayer(DIELECTRIC; thickness=-525μm, gds_meta=GDSMeta(100, 0)),
    :simulated_area => SourceLayer(NULL; offset=-1mm, thickness=2mm, gds_meta=nothing),
    :port => SourceLayer(NULL; gds_meta=nothing),
    :lumped_element => SourceLayer(NULL; gds_meta=nothing),
    :wave_port => SourceLayer(NULL; offset=-200μm, thickness=400μm, gds_meta=nothing),
    :mesh_control => SourceLayer(NULL; gds_meta=nothing);
    levels=(1 => 0μm,)
)

"""
    airbridge_operations(; bridge_height=10μm)

Return layer operations building air bridges from the `:bridge` and `:bridge_base` layers
into `:bridge_metal`.

As in [`SolidModels.staple_bridge_postrendering`](@ref), each bridge is a platform at
`bridge_height` over the intersection of the bridge and its base, joined to the chip surface
by legs along the edges where the platform's footprint meets the bridge's feet.
"""
function airbridge_operations(; bridge_height=10μm)
    return [
        SolidModelsExperimental.Intersect(:bridge_shadow, :bridge, :bridge_base),
        Translate(:bridge_platform, :bridge_shadow, 0μm, 0μm, bridge_height),
        Cut(:bridge_foot, :bridge, :bridge_base; remove_object=true, remove_tool=true),
        GetBoundary(:bridge_shadow_boundary, :bridge_shadow),
        GetBoundary(:bridge_foot_boundary, :bridge_foot),
        SolidModelsExperimental.Intersect(
            :bridge_leg,
            :bridge_shadow_boundary,
            :bridge_foot_boundary
        ),
        Extrude(:bridge_leg, bridge_height),
        # The boundary curves also bound the shadow and feet, so keep their entities.
        Remove(:bridge_shadow_boundary; remove_entities=false),
        Remove(:bridge_foot_boundary; remove_entities=false),
        Remove(:bridge_shadow),
        Remove(:bridge_foot),
        Fuse(:bridge_metal, (:bridge_leg, :bridge_platform); remove_sources=true)
    ]
end

"""
    singlechip_solidmodel_target(; wave_ports=false, bridge_height=10μm)

Return a `SolidModelTarget` for simulating a single-chip device built on
[`SINGLECHIP_STACK`](@ref).

The target forms `:metal` from the writeable area, the metal layers, and the air bridges;
extrudes `:substrate` and fills the rest of `:simulated_area` with `:vacuum`; and extracts the
domain boundary into `:exterior_boundary`. Lumped ports and the junction's lumped element are
cut out of the metal; with `wave_ports=true`, the `:wave_port` segments are extruded into
boundary patches instead of using lumped ports.
"""
function singlechip_solidmodel_target(; wave_ports=false, bridge_height=10μm)
    ports = wave_ports ? [Extrude(:wave_port)] : SolidModelsExperimental.LayerOp[]
    port_cuts = wave_ports ? (:lumped_element,) : (:port, :lumped_element)
    operations = [
        Fuse(:metal_negative),
        Cut(:metal, :metal, :metal_negative; remove_tool=true),
        Fuse(:metal, (:metal, :junction_leads); remove_sources=true),
        airbridge_operations(; bridge_height)...,
        Fuse(:metal, (:metal, :bridge_metal); remove_sources=true),
        Cut(:metal, :metal, port_cuts),
        # Mesh control geometry sets mesh sizes, but is not part of the simulated model.
        Remove(:mesh_control; remove_entities=false),
        Extrude(:substrate),
        Extrude(:simulated_area),
        # Restricting the model deletes segments on the domain boundary, so extrude them first.
        ports...,
        RestrictTo(:simulated_area),
        GetBoundary(:exterior_boundary, :simulated_area),
        # Consuming the domain would also delete its boundary faces, so keep its entities.
        Cut(:vacuum, :simulated_area, :substrate),
        Remove(:simulated_area; remove_entities=false)
    ]
    return SolidModelTarget(SINGLECHIP_STACK, operations)
end

include("utils.jl")
include("components/SimpleJunctions/SimpleJunctions.jl")
include("components/Transmons/Transmons.jl")
include("components/ReadoutResonators/ReadoutResonators.jl")

end # module
