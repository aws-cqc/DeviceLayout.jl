"""
    ExampleXYTermination

Component for terminating a coplanar waveguide with an open for driving a qubit via weak capacitive coupling.

Contains a taper to the desired CPW dimensions and an optional s-curve for floorplanning convenience.

# Parameters

  - `name = "xyterm"`: Name of component
  - `xy_length = 100μm`: Straight length of XY line before termination
  - `xy_style = Paths.CPW(3.3μm, 2μm)`: XY control line style after taper (near the qubit)
  - `xy_snake = Point(350μm, -100μm)`: If nonzero, add an s-curve to this point before the
    final `xy_length` straight section before terimation (in the component coordinate system,
    where the path starts with `feedline_style` from the origin pointing along the positive x-axis)
  - `xy_distance = 50μm`: Distance from XY termination to ground plane edge near qubit
  - `taper_length = 100μm`: Length of taper from `feedline_style` to `xy_style`
  - `feedline_style = Paths.CPW(10μm, 6μm)`: Initial style before taper towards qubit
  - `bridge = nothing`: `CoordinateSystem` holding the air bridge geometry
  - `bridge_spacing = 100μm`: Spacing of bridges on the line
  - `last_bridge = 50μm`: Distance from the last bridge to the end of the line

# Hooks

  - `line`: Input to be connected to a feedline
  - `qubit`: Distance `xy_distance` beyond the edge of the termination, with
    inward direction back towards the XY line
"""
@compdef struct ExampleXYTermination <: Component
    name = "xyterm"
    xy_length = 100μm
    xy_style = Paths.CPW(3.3μm, 2μm)
    xy_snake = Point(350μm, -100μm)
    xy_distance = 50μm
    taper_length = 100μm
    feedline_style = Paths.CPW(10μm, 6μm)
    bridge = nothing
    bridge_spacing = 100μm
    last_bridge = 50μm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, xy::ExampleXYTermination)
    path = _path(xy)
    if !isnothing(xy.bridge)
        simplify!(path, 2:length(path)) # Make non-tapered segments a single segment
        l = pathlength(path[end])
        positions = l .- ((xy.last_bridge):(xy.bridge_spacing):l)
        attach!(path, sref(xy.bridge), positions)
    end
    return place!(cs, path)
end

function _path(xy::ExampleXYTermination)
    (; xy_length, xy_snake, xy_style, feedline_style, taper_length) = parameters(xy)
    path = Path(; metadata=METAL_NEGATIVE)
    straight!(path, taper_length, Paths.TaperCPW(feedline_style, xy_style))
    !iszero(xy_snake) && route!(
        path,
        xy_snake,
        0°,
        Paths.StraightAnd45(min_bend_radius=(xy_snake.y / 2)),
        xy_style
    )
    straight!(path, xy_length, xy_style)
    terminate!(path; rounding=(xy_style.trace / 2))
    return path
end

function SchematicDrivenLayout.hooks(xy::ExampleXYTermination)
    path = _path(xy)
    straight!(path, xy.xy_distance, Paths.NoRender())
    return (; line=p0_hook(path), qubit=p1_hook(path))
end

"""
    ExampleZTermination <: Component

Component for terminating a coplanar waveguide with an asymmetric short, as to apply flux bias to a SQUID.

Contains a taper to the desired CPW dimensions and an optional bend for floorplanning convenience.

This component is intended for use in demonstrations.

Example (hooks marked with ⋆ and an arrow in their inward direction):

                      ██   (+z_cut_length + z_cut_offset) / 2 ⤒
                      ██
         z_style.gap →██←
                      ██
          ██████████████
    :line→⋆  z_style  ██|←z_distance→|⋆←:qubit              0 —
          ██████████  ██
          ←z_length→  ██
                      ██
                      ██   (-z_cut_length + z_cut_offset) / 2 ⤓

# Parameters

Note that when this component is created within an `ExampleStarTransmon`,
most of these defaults are overridden.

  - `name = "zterm"`: Name of component
  - `z_length = 100μm`: Straight length of Z line before termination
  - `z_style = Paths.CPW(3.3μm, 2μm)`: Style of the Z line near the qubit
  - `z_cut_offset = 0μm`: Offset of z cut relative to SQUID axis of symmetry
  - `z_cut_length = 16μm`: Length of cut defining a return current path shared by the SQUID loop
  - `z_distance = 2μm`: Distance from edge of ground plane cut to qubit
  - `z_bend_angle = -45°`: Angle of bend in Z line (moving towards the qubit)
  - `z_bend_radius = 140μm`: Radius of bend in Z line
  - `taper_length = 100μm`: Length of taper from `feedline_style` to `z_style`
  - `feedline_style = Paths.CPW(10μm, 6μm)`: Initial style before taper towards qubit
  - `bridge = nothing`: `CoordinateSystem` holding the air bridge geometry
  - `bridge_spacing = 30μm`: Spacing of bridges on the line
  - `last_bridge = 20μm`: Distance from the last bridge to the end of the line

# Hooks

  - `line`: Input to be connected to a feedline
  - `qubit`: Distance `z_distance` beyond the edge of the ground plane cut, with
    inward direction back towards the Z line
"""
@compdef struct ExampleZTermination <: Component
    name = "zterm"
    z_length = 100μm
    z_style = Paths.CPW(3.3μm, 2μm)
    z_cut_offset = 0μm
    z_cut_length = 16μm
    z_distance = 2μm
    z_bend_angle = -45°
    z_bend_radius = 140μm
    taper_length = 100μm
    feedline_style = Paths.CPW(10μm, 6μm)
    bridge = nothing
    bridge_spacing = 30μm
    last_bridge = 20μm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, z::ExampleZTermination)
    (; z_cut_offset, z_style, z_cut_length, bridge) = parameters(z)
    path = _path(z)

    if !isnothing(bridge)
        simplify!(path, 2:length(path)) # Make non-tapered segments a single segment
        l = pathlength(path[end])
        positions = l .- ((z.last_bridge):(z.bridge_spacing):l)
        attach!(path, sref(bridge), positions)
    end
    cuts_cs = CoordinateSystem(uniquename("zcuts"))

    sidecut =
        Rectangle(z_style.trace, z_style.gap) + Point(zero(z_cut_offset), z_style.trace / 2)
    cut = Align.rightof(centered(Rectangle(z_style.gap, z_cut_length)), sidecut)
    cut += Point(zero(z_cut_offset), z_cut_offset)
    place!(cuts_cs, cut, METAL_NEGATIVE)
    place!(cuts_cs, sidecut, METAL_NEGATIVE)
    attach!(path, sref(cuts_cs), pathlength(path[end]))
    return place!(cs, path, METAL_NEGATIVE)
end

function _path(z::ExampleZTermination)
    (; z_length, z_style, feedline_style, taper_length, z_bend_angle, z_bend_radius) =
        parameters(z)
    path = Path(; metadata=METAL_NEGATIVE)
    straight!(path, taper_length, Paths.TaperCPW(feedline_style, z_style))
    !iszero(z_bend_angle) && turn!(path, z_bend_angle, z_bend_radius, z_style)
    straight!(path, z_length, z_style)
    return path
end

function SchematicDrivenLayout.hooks(z::ExampleZTermination)
    path = _path(z)
    straight!(path, z.z_style.trace + z.z_style.gap + z.z_distance, Paths.NoRender())
    return (; line=p0_hook(path), qubit=p1_hook(path))
end
