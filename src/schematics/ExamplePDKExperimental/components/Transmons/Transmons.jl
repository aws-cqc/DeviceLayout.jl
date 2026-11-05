"""
    module Transmons

An `ExamplePDKExperimental` component module containing a simple rectangular transmon.

`ExamplePDKExperimental` is intended for demonstrations, tutorials, and tests. **Breaking
changes may occur within major versions.** Don't depend on it in your own PDK or for real
devices!
"""
module Transmons

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
import DeviceLayout.SolidModelsExperimental: LayerRef, Locator, Terminal
import ..ExamplePDKExperimental.SimpleJunctions: ExampleSimpleJunction

export ExampleRectangleTransmon

"""
    struct ExampleRectangleTransmon <: CompositeComponent
    ExampleRectangleTransmon(base_parameters::NamedTuple=default_parameters(ExampleRectangleTransmon);
        kwargs...)

Transmon component with a rectangular island acting as a shunt capacitor across a junction,
as [`ExamplePDK.Transmons.ExampleRectangleTransmon`](@ref SchematicDrivenLayout.ExamplePDK.Transmons.ExampleRectangleTransmon).

The island carries a [`Terminal`](@ref DeviceLayout.SolidModelsExperimental.Terminal) locator
named `"island"`.

# Parameters

  - `name = "tr"`: Name of component
  - `jj_template = ExampleSimpleJunction()`: Template to generate the junction, where `name`
    and `ground_island_length` will be overridden
  - `cap_width = 24μm`: The width of the rectangular island
  - `cap_length = 520μm`: The length of the rectangular island
  - `cap_gap = 30μm`: The gap surrounding the rectangular island, except the side with the junction
  - `junction_gap = 12μm`: The gap on the side of the island where the junction will go
  - `junction_pos = :bottom`: Location to place the junction (options `:top` or `:bottom`)
  - `island_rounding = 0µm`: Optional rounding radius to apply to the island; if zero, no
    rounding is applied to the island

# Hooks

  - `readout`: The center edge of the ground plane on the opposite side of the island from the junction.
  - `xy`: The left side of the capacitor gap.
  - `z`: The center edge of the ground plane at the junction.

# Subcomponents

 1. `island::ExampleRectangleIsland`
 2. `junction::typeof(jj_template)`
"""
@compdef struct ExampleRectangleTransmon <: CompositeComponent
    name = "tr"
    jj_template = ExampleSimpleJunction()
    cap_width = 24μm
    cap_length = 520μm
    cap_gap = 30μm
    junction_gap = 12μm
    junction_pos = :bottom
    island_rounding::typeof(1.0µm) = 0µm
end

function SchematicDrivenLayout._build_subcomponents(tr::ExampleRectangleTransmon)
    island_params = filter_parameters(ExampleRectangleIsland, tr)
    @component island = ExampleRectangleIsland(; island_params...)

    @component junction = tr.jj_template begin
        ground_island_length = tr.junction_gap
    end

    return (island, junction)
end

function SchematicDrivenLayout._graph!(
    g::SchematicGraph,
    comp::ExampleRectangleTransmon,
    subcomps::NamedTuple
)
    island_node = add_node!(g, subcomps.island)
    return fuse!(g, island_node => :junction, subcomps.junction => :island)
end

function SchematicDrivenLayout.map_hooks(::Type{ExampleRectangleTransmon})
    return Dict((1 => :readout) => :readout, (1 => :xy) => :xy, (1 => :z) => :z)
end

SchematicDrivenLayout.check_rotation(::ExampleRectangleTransmon) = true
SchematicDrivenLayout.allowed_rotation_angles(::ExampleRectangleTransmon) = [0]

"""
    ExampleRectangleIsland <: Component

Example transmon capacitor consisting of a rectangle, with surrounding gap and optional
rounding, and a [`Terminal`](@ref DeviceLayout.SolidModelsExperimental.Terminal) locator named
`"island"` at its center.

# Parameters

Note that when this component is created within an `ExampleRectangleTransmon`, these defaults are
overwritten.

  - `name = "island"`: Name of component
  - `cap_width = 24μm`: The width of the rectangular island
  - `cap_length = 520μm`: The length of the rectangular island
  - `cap_gap = 30μm`: The gap surrounding the rectangular island, except the side with the junction
  - `junction_gap = 12μm`: The gap on the side of the island where the junction will go
  - `junction_pos = :bottom`: Location to place the junction (options `:top` or `:bottom`)
  - `island_rounding = 0µm`: Optional rounding radius to apply to the island; if zero, no
    rounding is applied to the island

# Hooks

  - `junction`: Attachment point where junction leads meet the island
  - `readout`: Claw attachment point for the readout resonator, opposite the `junction_pos`.
  - `xy`: Attachment point for the XY line (left side, midpoint of island)
  - `z`: Attachment point for the Z line
"""
@compdef struct ExampleRectangleIsland <: Component
    name = "island"
    cap_width = 24μm
    cap_length = 520μm
    cap_gap = 30μm
    junction_gap = 12μm
    junction_pos = :bottom
    island_rounding::typeof(1.0µm) = 0µm
end

function SchematicDrivenLayout.hooks(r::ExampleRectangleIsland)
    (; junction_gap, junction_pos, cap_width, cap_length, cap_gap) = r

    cutout_height = junction_gap + cap_length + cap_gap
    sgn = junction_pos == :bottom ? 1 : -1
    junction = PointHook(Point(0μm, sgn * junction_gap), sgn * 90°) # junction lead meets island
    readout = PointHook(Point(0μm, sgn * cutout_height), sgn * -90°) # top of cap gap
    xy = PointHook(
        Point(-cap_gap - cap_width / 2, sgn * cutout_height / 3), # left side of capacitor gap
        0°
    )
    z = PointHook(Point(0μm, 0μm), sgn * 90°) # Center of ground edge at the junction

    return (; junction, readout, xy, z)
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, r::ExampleRectangleIsland)
    (; junction_gap, junction_pos, cap_width, cap_length, cap_gap, island_rounding) = r
    sgn = junction_pos == :bottom ? 1 : -1
    island_rect = Rectangle(
        Point(-cap_width / 2, sgn * junction_gap),
        Point(cap_width / 2, sgn * (junction_gap + cap_length))
    )
    cutout_rect = Rectangle(
        Point(-cap_width / 2 - cap_gap, zero(cap_gap)),
        Point(cap_width / 2 + cap_gap, sgn * (junction_gap + cap_length + cap_gap))
    )
    cutout = Rounded(island_rounding)(difference2d(cutout_rect, island_rect))
    place!(cs, Locator(center(island_rect)), Terminal(:metal, "island"))

    return place!(
        cs,
        meshsized_entity(cutout, 2 * min(cap_width, cap_gap)),
        LayerRef(:metal_negative)
    )
end

end # module
