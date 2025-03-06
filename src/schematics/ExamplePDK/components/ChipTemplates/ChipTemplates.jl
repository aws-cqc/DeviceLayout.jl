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
  - `num_ports_lr = 12`: Number of ports on the left and right edges
  - `num_ports_tb = 12`: Number of ports on the top and bottom edges
  - `length_x = 15mm`: x length of chip
  - `length_y = 15mm`: y length of chip
  - `dx = 1mm`: x spacing of ports on top and bottom
  - `dy = 1mm`: y spacing of ports on left and right
  - `edge_gap_lr = 0.050mm`: Gap between chip edge and ports on left and right
  - `edge_gap_tb = 0.050mm`: Gap between chip edge and ports on top and bottom

# Hooks

  - `port_i`: Uniformly spaced around the edge of the chip with `in_direction` towards the
    edge of the chip, with `i` beginning at 1 at the top left and increasing clockwise
"""
@compdef struct ExampleChip <: Component
    name = "chip"
    num_ports_lr = 12
    num_ports_tb = 12
    length_x = 15mm
    length_y = 15mm
    dx = 1mm
    dy = 1mm
    edge_gap_lr = 0.050mm
    edge_gap_tb = 0.050mm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, c::ExampleChip)
    chip_rect = centered(Rectangle(c.length_x, c.length_y))
    # only_simulated would make these invisible to `bounds`, which we don't want
    # so these render by default and ignore for artwork
    not_artwork =
        OptionalStyle(DeviceLayout.NoRender(), DeviceLayout.Plain(), :artwork, false)
    place!(cs, not_artwork(chip_rect), CHIP_AREA)
    return place!(cs, not_artwork(chip_rect), WRITEABLE_AREA)
end

function SchematicDrivenLayout.hooks(c::ExampleChip)
    x0 = c.dx * (c.num_ports_lr - 1) / 2
    y0 = c.dy * (c.num_ports_tb - 1) / 2
    # Clockwise from left corner of top edge
    xt = range(-x0, step=c.dx, length=c.num_ports_tb)
    xb = -xt
    xl = fill(-c.length_x / 2 + c.edge_gap_lr, c.num_ports_lr)
    xr = -xl
    yb = fill(-c.length_y / 2 + c.edge_gap_tb, c.num_ports_tb)
    yt = -yb
    yl = range(-y0, step=c.dy, length=c.num_ports_lr)
    yr = -yl
    x = vcat(xt, xr, xb, xl)
    y = vcat(yt, yr, yb, yl)
    dirs = vcat(
        fill(90°, c.num_ports_tb),
        fill(0°, c.num_ports_lr),
        fill(270°, c.num_ports_tb),
        fill(180°, c.num_ports_lr)
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
    render!(port_cs, only_simulated(centered(Rectangle(gap0, gap0))), PORT)
    attach!(path, sref(port_cs), path[1].sty.gap / 2, i=1)
    return path
end
###

end # module
