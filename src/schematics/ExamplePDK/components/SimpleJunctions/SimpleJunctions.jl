"""
    module SimpleJunctions

An `ExamplePDK` component module containing simple placeholder Josephson junctions and SQUIDs.

`ExamplePDK` is intended for demonstrations, tutorials, and tests. While we aim to
demonstrate best practices for Julia code and DeviceLayout.jl usage, these components are not
optimized for device performance. Most importantly: **Breaking changes to `ExamplePDK` may
occur within major versions.** In other words, don't depend on `ExamplePDK` in your own PDK
or for real devices!
"""
module SimpleJunctions

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
using .SchematicDrivenLayout.ExamplePDK, .ExamplePDK.LayerVocabulary

"""
    ExampleSimpleJunction <: Component

An example Josephson junction component with placeholder artwork.

This example component showcases that you can draw different geometry for different rendering
targets. Junctions are often defined using double-angle evaporation, resulting in a physical
metal pattern distinct from the geometry used for lithography. While it's possible to calculate
that metal pattern based on process parameters like resist thicknesses and deposition angles,
in this case, we take a shortcut and just define different rectangles for "artwork" and
"simulation" which will be used or ignored based on rendering options.

The "artwork" geometry contains an unrealistic placeholder pattern in a single `JUNCTION_PATTERN`
layer. The "simulation" geometry adds `METAL_POSITIVE` rectangles representing junction leads,
connected by a `LUMPED_ELEMENT` rectangle.

     :island hook
        ↓    
        ⋆           —
        █           ↑  
        █           │
        █           │
        ▒↕ h_jj     h_ground_island
        █           │
       →█← w_jj     │
        █           ↓
        ⋆           —
        ↑    
     :ground hook

# Parameters

  - `name = "junction"`: Name of component
  - `w_jj = 1μm`: Width of JJ and lead
  - `h_jj = 1μm`: Height of JJ port rectangle / gap between leads
  - `h_ground_island = 20μm`: Total JJ ground-to-island height
  - `h_excess = 2μm`: Additional JJ lead height overlapping each of ground and island

# Hooks

  - `island`: Hook where the "top" (in JJ coordinate system) JJ lead should meet the island,
    inward direction pointing down
  - `ground`: Hook where the "bottom" JJ lead should meet ground, inward direction pointing up
"""
@compdef struct ExampleSimpleJunction <: Component
    name = "junction"
    w_jj = 1μm
    h_jj = 1μm
    h_ground_island = 20μm
    h_excess = 2μm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, jj::ExampleSimpleJunction)
    (; w_jj, h_jj, h_ground_island, h_excess) = jj
    # simulation geometry
    jj_rect = centered(Rectangle(w_jj, h_jj))
    top_lead =
        Align.above(Rectangle(w_jj, (h_ground_island - h_jj) / 2), jj_rect; centered=true)
    bot_lead = Align.below(top_lead, jj_rect)
    place!(cs, only_simulated(jj_rect), LUMPED_ELEMENT)
    place!(cs, MeshSized(2 * w_jj)(only_simulated(top_lead)), METAL_POSITIVE)
    place!(cs, MeshSized(2 * w_jj)(only_simulated(bot_lead)), METAL_POSITIVE)
    # artwork geometry
    top_lead_art = Align.above(
        Rectangle(w_jj, (h_ground_island - h_jj) / 2 + h_excess),
        jj_rect;
        centered=true
    )
    bot_lead_art = Align.below(top_lead_art, jj_rect)
    place!(cs, not_simulated(top_lead_art), JUNCTION_PATTERN)
    return place!(cs, not_simulated(bot_lead_art), JUNCTION_PATTERN)
end

function SchematicDrivenLayout.hooks(jj::ExampleSimpleJunction)
    return (;
        island = PointHook(0μm, jj.h_ground_island / 2, -90°),
        ground = PointHook(0μm, -jj.h_ground_island / 2, 90°)
    )
end

SchematicDrivenLayout.check_rotation(::ExampleSimpleJunction) = true
SchematicDrivenLayout.allowed_rotation_angles(::ExampleSimpleJunction) = [0°, 180°]

"""
    ExampleSimpleSQUID <: CompositeComponent

An example SQUID consisting of two [`ExampleSimpleJunction`](@ref)s.

The "artwork" geometry contains an unrealistic placeholder pattern in a single `JUNCTION_PATTERN`
layer. The "simulation" geometry adds `METAL_POSITIVE` rectangles representing junction leads,
connected by a `LUMPED_ELEMENT` rectangle.

      :island hook
         ↓    
         ⋆                —
    █         █           ↑
    █         █           │
    █         █           │
    ▒         ▒↕ h_jj     h_ground_island
    █         █           │
    █        →█← w_jj     │
    █         █           ↓
         ⋆                —
         ↑
         :ground hook

# Parameters

  - `name = "squid"`: Name of component
  - `jj_templates = (ExampleSimpleJunction(), ExampleSimpleJunction())`: Templates for left and
    right (in the SQUID coordinate system) JJs, respectively, used to specify parameters not
    overridden by the SQUID
  - `h_ground_island = 20μm`: Total JJ ground-to-island height
  - `h_excess = 2μm`: Additional JJ lead height overlapping each of ground and island
  - `w_squid`: Distance between left and right JJs

# Hooks

  - `island`: Hook at the center of the "top" (in SQUID coordinate system) edge of the SQUID loop
    meant to coincide with the edge of the island metal, inward direction pointing down
"""
@compdef struct ExampleSimpleSQUID <: CompositeComponent
    name = "squid"
    jj_templates = (ExampleSimpleJunction(), ExampleSimpleJunction())
    h_ground_island = 20μm
    h_excess = 2μm
    w_squid = 10μm
end

function SchematicDrivenLayout._build_subcomponents(sq::ExampleSimpleSQUID)
    @component jj1 = sq.jj_templates[1] begin
        h_ground_island = sq.h_ground_island
        h_excess = sq.h_excess
    end
    @component jj2 = sq.jj_templates[2] begin
        h_ground_island = sq.h_ground_island
        h_excess = sq.h_excess
    end
    @component spacer_left =
        Spacer{coordinatetype(sq)}(p1=Point(-sq.w_squid / 2, zero(sq.w_squid)))
    @component spacer_right =
        Spacer{coordinatetype(sq)}(p1=Point(sq.w_squid / 2, zero(sq.w_squid)))

    return (jj1, jj2, spacer_left, spacer_right)
end

function SchematicDrivenLayout._graph!(
    g::SchematicGraph,
    comp::ExampleSimpleSQUID,
    subcomps::NamedTuple
)
    jj1_node = add_node!(g, subcomps.jj1)
    jj2_node = add_node!(g, subcomps.jj2)
    spacer_left_node = fuse!(g, jj1_node => :island, subcomps.spacer_left => :p1_north)
    spacer_right_node = fuse!(g, jj2_node => :island, subcomps.spacer_right => :p1_north)
    return fuse!(g, spacer_left_node => :p0_south, spacer_right_node => :p0_north)
end

function SchematicDrivenLayout.map_hooks(tr::ExampleSimpleSQUID)
    ###### Dictionary mapping (graph node index => subcomp hook name) => MyComp hook name
    return Dict((3 => :p0_south) => :island)
end

SchematicDrivenLayout.check_rotation(::ExampleSimpleSQUID) = true
SchematicDrivenLayout.allowed_rotation_angles(::ExampleSimpleSQUID) = [0°, 180°]

end # module
