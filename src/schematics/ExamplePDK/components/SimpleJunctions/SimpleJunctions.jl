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
        ▒↕ junction_lead_gap  ground_island_length
        █           │
       →█← junction_width     │
        █           ↓
        ⋆           —
        ↑
     :ground hook

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
    jj_rect = centered(Rectangle(junction_width, junction_lead_gap))
    top_lead = Align.above(
        Rectangle(junction_width, (ground_island_length - junction_lead_gap) / 2),
        jj_rect;
        centered=true
    )
    bot_lead = Align.below(top_lead, jj_rect)
    place!(cs, only_simulated(WithDirection(jj_rect, 90°)), LUMPED_ELEMENT)
    place!(cs, MeshSized(2 * junction_width)(only_simulated(top_lead)), METAL_POSITIVE)
    place!(cs, MeshSized(2 * junction_width)(only_simulated(bot_lead)), METAL_POSITIVE)
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
    place!(cs, not_simulated(top_lead_art), JUNCTION_PATTERN)
    return place!(cs, not_simulated(bot_lead_art), JUNCTION_PATTERN)
end

function SchematicDrivenLayout.hooks(jj::ExampleSimpleJunction)
    return (;
        island = PointHook(0μm, jj.ground_island_length / 2, -90°),
        ground = PointHook(0μm, -jj.ground_island_length / 2, 90°)
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
    ▒         ▒↕ junction_lead_gap  ground_island_length
    █         █           │
    █        →█← junction_width     │
    █         █           ↓
         ⋆                —
         ↑
         :ground hook

# Parameters

  - `name = "squid"`: Name of component
  - `jj_templates = (ExampleSimpleJunction(), ExampleSimpleJunction())`: Templates for left and
    right (in the SQUID coordinate system) JJs, respectively, used to specify parameters not
    overridden by the SQUID
  - `ground_island_length = 20μm`: Total JJ ground-to-island length
  - `lead_excess_length = 2μm`: Additional JJ lead length overlapping each of ground and island
  - `squid_width`: Distance between left and right JJs

# Hooks

  - `island`: Hook at the center of the "top" (in SQUID coordinate system) edge of the SQUID loop
    meant to coincide with the edge of the island metal, inward direction pointing down
"""
@compdef struct ExampleSimpleSQUID <: CompositeComponent
    name = "squid"
    jj_templates = (ExampleSimpleJunction(), ExampleSimpleJunction())
    ground_island_length = 20μm
    lead_excess_length = 2μm
    squid_width = 10μm
end

function SchematicDrivenLayout._build_subcomponents(sq::ExampleSimpleSQUID)
    @component jj1 = sq.jj_templates[1] begin
        ground_island_length = sq.ground_island_length
        lead_excess_length = sq.lead_excess_length
    end
    @component jj2 = sq.jj_templates[2] begin
        ground_island_length = sq.ground_island_length
        lead_excess_length = sq.lead_excess_length
    end
    @component spacer_left =
        Spacer{coordinatetype(sq)}(p1=Point(-sq.squid_width / 2, zero(sq.squid_width)))
    @component spacer_right =
        Spacer{coordinatetype(sq)}(p1=Point(sq.squid_width / 2, zero(sq.squid_width)))

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

# Graph node indices, in the order subcomponents are returned by `_build_subcomponents`
# (and added in `_graph!`). Centralizing the index↔subcomponent mapping keeps `map_hooks`
# from hardcoding a bare integer that must track the build order by hand.
const _SIMPLE_SQUID_NODES = (jj1=1, jj2=2, spacer_left=3, spacer_right=4)

function SchematicDrivenLayout.map_hooks(tr::ExampleSimpleSQUID)
    ###### Dictionary mapping (graph node index => subcomp hook name) => MyComp hook name
    n = _SIMPLE_SQUID_NODES
    return Dict((n.spacer_left => :p0_south) => :island)
end

SchematicDrivenLayout.check_rotation(::ExampleSimpleSQUID) = true
SchematicDrivenLayout.allowed_rotation_angles(::ExampleSimpleSQUID) = [0°, 180°]

end # module
