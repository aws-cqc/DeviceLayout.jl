"""
    module SimpleJunctionsExperimental

An `ExamplePDKExperimental` component module containing a simple placeholder Josephson
junction.

`ExamplePDKExperimental` is intended for demonstrations, tutorials, and tests. **Breaking
changes may occur within major versions.** Don't depend on it in your own PDK or for real
devices!
"""
module SimpleJunctionsExperimental

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
import DeviceLayout.SolidModelsExperimental: LayerRef, Locator, LumpedPort

export ExampleSimpleJunction

"""
    ExampleSimpleJunction <: Component

An example Josephson junction component with placeholder artwork, as
[`ExamplePDK.SimpleJunctions.ExampleSimpleJunction`](@ref SchematicDrivenLayout.ExamplePDK.SimpleJunctions.ExampleSimpleJunction).

The "simulation" geometry consists of `:junction_leads` connected by a `:lumped_element`
rectangle, which carries a [`LumpedPort`](@ref
DeviceLayout.SolidModelsExperimental.LumpedPort) locator named `"junction"`. The "artwork"
geometry is on `:junction_pattern`. Which geometry appears in each output is set by the
`gds_meta` and `solidmodel` of these layers in the stack.

# Parameters

  - `name = "junction"`: Name of component
  - `junction_width = 1μm`: Width of JJ and lead
  - `junction_lead_gap = 1μm`: Length of JJ port rectangle / gap between leads
  - `ground_island_length = 20μm`: Total JJ ground-to-island length
  - `lead_excess_length = 2μm`: Additional JJ lead length overlapping each of ground and island

# Hooks

  - `island`: Hook where the "top" (in JJ coordinate system) JJ lead should meet the island,
    inward direction pointing down
  - `ground`: Hook where the "bottom" JJ lead should meet ground, inward direction pointing up
"""
@compdef struct ExampleSimpleJunction <: Component
    name = "junction"
    junction_width = 1μm
    junction_lead_gap = 1μm
    ground_island_length = 20μm
    lead_excess_length = 2μm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, jj::ExampleSimpleJunction)
    (; junction_width, junction_lead_gap, ground_island_length, lead_excess_length) = jj
    # simulation geometry
    jj_rect = centered(Rectangle(junction_width, junction_lead_gap)) |> WithDirection(90°)
    top_lead = Align.above(
        Rectangle(junction_width, (ground_island_length - junction_lead_gap) / 2),
        jj_rect;
        centered=true
    )
    bot_lead = Align.below(top_lead, jj_rect)
    place!(cs, jj_rect, LayerRef(:lumped_element))
    place!(cs, Locator(center(jj_rect)), LumpedPort(:lumped_element, "junction"))
    place!(cs, MeshSized(2 * junction_width)(top_lead), LayerRef(:junction_leads))
    place!(cs, MeshSized(2 * junction_width)(bot_lead), LayerRef(:junction_leads))
    # artwork geometry
    top_lead_art = Align.above(
        Rectangle(
            junction_width,
            (ground_island_length - junction_lead_gap) / 2 + lead_excess_length
        ),
        jj_rect;
        centered=true
    )
    bot_lead_art = Align.below(top_lead_art, jj_rect)
    place!(cs, top_lead_art, LayerRef(:junction_pattern))
    return place!(cs, bot_lead_art, LayerRef(:junction_pattern))
end

function SchematicDrivenLayout.hooks(jj::ExampleSimpleJunction)
    return (;
        island = PointHook(0μm, jj.ground_island_length / 2, -90°),
        ground = PointHook(0μm, -jj.ground_island_length / 2, 90°)
    )
end

SchematicDrivenLayout.check_rotation(::ExampleSimpleJunction) = true
SchematicDrivenLayout.allowed_rotation_angles(::ExampleSimpleJunction) = [0°, 180°]

end # module
