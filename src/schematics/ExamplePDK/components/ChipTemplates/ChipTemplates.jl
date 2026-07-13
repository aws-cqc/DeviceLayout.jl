"""
    module ChipTemplates

An `ExamplePDK` component module containing simple chips and coplanar-waveguide launchers.

`ExamplePDK` is intended for demonstrations, tutorials, and tests. While we aim to
demonstrate best practices for Julia code and DeviceLayout.jl usage, these components are not
optimized for device performance. Most importantly: **Breaking changes to `ExamplePDK` may
occur within major versions.** In other words, don't depend on `ExamplePDK` in your own PDK
or for real devices!
"""
module ChipTemplates

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
using .SchematicDrivenLayout.ExamplePDK, .ExamplePDK.LayerVocabulary

export ExampleChip, example_launcher

### ExampleChip
"""
    struct ExampleChip <: Component

A `Component` with rectangular geometry in the CHIP_AREA layer and uniformly spaced hooks.

# Parameters

  - `name = "chip"`: Name of component
  - `port_lr_count = 12`: Number of ports on the left and right edges
  - `port_tb_count = 12`: Number of ports on the top and bottom edges
  - `chip_x_length = 15mm`: x length of chip
  - `chip_y_length = 15mm`: y length of chip
  - `port_tb_pitch = 1mm`: x spacing of ports on top and bottom
  - `port_lr_pitch = 1mm`: y spacing of ports on left and right
  - `port_lr_edge_gap = 0.050mm`: Gap between chip edge and ports on left and right
  - `port_tb_edge_gap = 0.050mm`: Gap between chip edge and ports on top and bottom

# Hooks

  - `port_i`: Uniformly spaced around the edge of the chip with `in_direction` towards the
    edge of the chip, with `i` beginning at 1 at the top left and increasing clockwise
"""
@compdef struct ExampleChip <: Component
    name = "chip"
    port_lr_count = 12
    port_tb_count = 12
    chip_x_length = 15mm
    chip_y_length = 15mm
    port_tb_pitch = 1mm
    port_lr_pitch = 1mm
    port_lr_edge_gap = 0.050mm
    port_tb_edge_gap = 0.050mm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, c::ExampleChip)
    chip_rect = centered(Rectangle(c.chip_x_length, c.chip_y_length))
    # only_simulated would make these invisible to `bounds`, which we don't want
    # so these render by default and ignore for artwork
    not_artwork =
        OptionalStyle(DeviceLayout.NoRender(), DeviceLayout.Plain(), :artwork, false)
    place!(cs, not_artwork(chip_rect), CHIP_AREA)
    return place!(cs, not_artwork(chip_rect), WRITEABLE_AREA)
end

function SchematicDrivenLayout.hooks(c::ExampleChip)
    x0 = c.port_tb_pitch * (c.port_lr_count - 1) / 2
    y0 = c.port_lr_pitch * (c.port_tb_count - 1) / 2
    # Clockwise from left corner of top edge
    xt = range(-x0, step=c.port_tb_pitch, length=c.port_tb_count)
    xb = -xt
    xl = fill(-c.chip_x_length / 2 + c.port_lr_edge_gap, c.port_lr_count)
    xr = -xl
    yb = fill(-c.chip_y_length / 2 + c.port_tb_edge_gap, c.port_tb_count)
    yt = -yb
    yl = range(-y0, step=c.port_lr_pitch, length=c.port_lr_count)
    yr = -yl
    x = vcat(xt, xr, xb, xl)
    y = vcat(yt, yr, yb, yl)
    dirs = vcat(
        fill(90°, c.port_tb_count),
        fill(0°, c.port_lr_count),
        fill(270°, c.port_tb_count),
        fill(180°, c.port_lr_count)
    )
    return (; port=PointHook.(Point.(x, y), dirs), origin=PointHook(0mm, 0mm, -180°))
end
###

### Launcher
"""
    example_launcher(port_spec)

Create a coplanar-waveguide "launcher" in `METAL_NEGATIVE` created using `launch!`.

Returns a `Path` named `"launcher_\$role_\$target"`, where `role` and `target` are the first two
elements of `port_spec`. Hooks are given by [`hooks(::Path)`](@ref). Uses default parameters
for `launch!` with rounding turned off.

The simulated-only `PORT` rectangle carries a [`WithDirection`](@ref) style (default `0°`,
along the launch direction) so that its orientation after placement can be retrieved with
`ExamplePDK.port_directions` to configure simulations.

This method exists for use in demonstrations. The launcher design is not optimized
for microwave properties.
"""
function example_launcher(port_spec)
    isnothing(port_spec) && return nothing
    path =
        Path(nm; name="launcher_$(port_spec[1])_$(port_spec[2])", metadata=METAL_NEGATIVE)
    launch!(path, extround=0μm)
    port_cs = CoordinateSystem(uniquename("launcherport"))
    gap0 = path[1].sty.gap # Launcher pad gap
    render!(
        port_cs,
        only_simulated(
            WithDirection(meshsized_entity(centered(Rectangle(gap0, gap0)), gap0 / 2))
        ),
        PORT
    )
    attach!(path, sref(port_cs), path[1].sty.gap / 2, i=1)
    return path
end
###

end # module
