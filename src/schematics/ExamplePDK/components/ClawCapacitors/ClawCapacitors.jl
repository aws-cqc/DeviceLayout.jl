"""
    module ClawCapacitors

An `ExamplePDK` component module containing claw capacitors for coupling coplanar
waveguides in shunt and series configurations.

`ExamplePDK` is intended for demonstrations, tutorials, and tests. While we aim to
demonstrate best practices for Julia code and DeviceLayout.jl usage, these components are not
optimized for device performance. Most importantly: **Breaking changes to `ExamplePDK` may
occur within major versions.** In other words, don't depend on `ExamplePDK` in your own PDK
or for real devices!
"""
module ClawCapacitors

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
using .SchematicDrivenLayout.ExamplePDK, .ExamplePDK.LayerVocabulary

import .ExamplePDK: tap!

export ExampleSeriesClawCapacitor, ExampleShuntClawCapacitor

"""
    ExampleSeriesClawCapacitor <: Component

Series capacitor between two coplanar lines. The input forms a claw around a pad at the output.

Contains hooks `p0` at the input and `p1` at the output, as well as left-handed versions `p0_lh`
and `p1_lh`. (When left-handed hooks are fused to right-handed hooks, an extra reflection is applied
when aligning the hooks—see [`HandedPointHook`](@ref).)

This component is intended for use in demonstrations.

                     claw_inner_gap
                      ←——→   ←——→
                  ███████████████████
                  ██               ██
                  ██  ███████████  ██ ↑ claw_inner_gap
                  ██  ███████████  ██ ↓
    ←input_length→██  ████ ↑ ████  ██
    ████████████████  ████ | ████████                                
    input_style       ████ inner_cap_length  ↕ output_style.trace    
    ████████████████  ████ | ████████        ↕ output_style.gap        
                  ██  ████ ↓ ████  ██
                  ██  ███████████  ██  
                  ██←→███████████  ██ 
                  ██claw_width↕    ██
                 ↕███████████████████
    claw_outer_gap←→      ←—→ inner_cap_width

# Parameters

  - `name = "claw"`: Name of component
  - `input_length = 2μm`: Length of input segment
  - `input_style = Paths.CPW(10μm, 6μm)`: Style of input path
  - `inner_cap_width = 20μm`: Width (short dimension, usually) of inner capacitor pad
  - `inner_cap_length = 200μm`: Length (long dimension) of inner capacitor pad
  - `claw_inner_gap = 5μm`: Gap between claw and inner pad
  - `claw_width = 10μm`: Width of claw metal trace
  - `claw_outer_gap = 20μm`: Outer gap around claw
  - `output_style = Paths.CPW(10μm, 6μm)`: Style of output path
  - `rounding = 2μm`: Rounding radius applied to the capacitor

# Hooks

  - `p0`: Input
  - `p1`: Output
  - `p0_lh`: Input (left-handed)
  - `p1_lh`: Output (left-handed)
"""
@compdef struct ExampleSeriesClawCapacitor <: Component
    name = "claw"
    input_length = 2μm
    input_style = Paths.CPW(10μm, 6μm)
    inner_cap_width = 20μm
    inner_cap_length = 200μm
    claw_inner_gap = 5μm
    claw_width = 10μm
    claw_outer_gap = 20μm
    output_style = Paths.CPW(10μm, 6μm)
    rounding = 2μm
end

function SchematicDrivenLayout._geometry!(
    cs::CoordinateSystem,
    cc::ExampleSeriesClawCapacitor
)
    path = _path(cc)
    place!(cs, path)
    claw_cutout = RotationPi(1 // 2)(_series_claw(cc))
    ms = MeshSized(critical_dimension(cc))
    place!(cs, ms(Align.rightof(claw_cutout, path, centered=true)), METAL_NEGATIVE)

    return cs
end

function _path(cc::ExampleSeriesClawCapacitor)
    (;
        input_length,
        input_style,
        rounding,
        claw_outer_gap,
        claw_width,
        claw_inner_gap,
        inner_cap_width
    ) = cc
    pa = Path(metadata=METAL_NEGATIVE, name=uniquename("$(cc.name)_in"))
    if (input_length - rounding) > zero(input_length)
        straight!(pa, input_length - rounding, input_style)
    end
    straight!(
        pa,
        2 * (claw_outer_gap + claw_width + claw_inner_gap + rounding) + inner_cap_width,
        Paths.NoRender()
    )
    return pa
end

function SchematicDrivenLayout.hooks(cc::ExampleSeriesClawCapacitor)
    path = _path(cc)
    return hooks(path)
end

function _series_claw(cc)
    (;
        input_style,
        inner_cap_width,
        inner_cap_length,
        claw_inner_gap,
        claw_width,
        claw_outer_gap,
        output_style,
        rounding
    ) = cc

    ## Claw
    # Output positive metal
    inner_pad = centered(Rectangle(inner_cap_length, inner_cap_width))
    output_trace = Rectangle(
        output_style.trace,
        claw_inner_gap + claw_width + claw_outer_gap + rounding
    )
    output_trace = Align.below(output_trace, inner_pad; centered=true)

    # Claw negatives
    # Use `halo` to get larger rectangle around original
    # Halo returns a vector, but we know it's length 1
    inner_hole = only(halo(inner_pad, claw_inner_gap))
    output_trace_hole = Rectangle(output_style.trace + 2 * claw_inner_gap, claw_width)
    output_trace_hole = Align.below(output_trace_hole, inner_hole; centered=true)
    # Claw positive
    claw_rect = only(halo(inner_hole, claw_width))
    claw_poly = only(to_polygons(difference2d(claw_rect, [inner_hole, output_trace_hole])))
    input_trace = Rectangle(input_style.trace, claw_outer_gap + rounding)
    input_trace = Align.above(input_trace, claw_poly; centered=true)

    # Outer cutout (negatives)
    cutout_rect = only(halo(claw_rect, claw_outer_gap))
    input_cutout_tail = Align.above(
        Rectangle(2 * Paths.extent(input_style), rounding),
        cutout_rect;
        centered=true
    )
    output_cutout_tail = Align.below(
        Rectangle(2 * Paths.extent(output_style), rounding),
        cutout_rect;
        centered=true
    )

    # Generate entire polygon
    outer_negatives = [cutout_rect, input_cutout_tail, output_cutout_tail]
    positives = [inner_pad, output_trace, claw_poly, input_trace]
    cutout_poly = only(to_polygons(union2d(difference2d(outer_negatives, positives))))
    # Round except for interface points
    interface_points = findall(
        pt ->
            gety(pt) == lowerleft(cutout_poly).y ||
                gety(pt) == upperright(cutout_poly).y,
        points(cutout_poly)
    )
    rounded =
        Rounded(rounding; p0=points(cutout_poly)[interface_points], inverse_selection=true)
    return rounded(cutout_poly)
end

function critical_dimension(cc)
    return min(
        cc.input_style.trace,
        cc.input_style.gap,
        cc.inner_cap_width,
        cc.inner_cap_length,
        cc.claw_inner_gap,
        cc.claw_width,
        cc.claw_outer_gap,
        cc.output_style.trace,
        cc.output_style.gap
    )
end

"""
    ExampleShuntClawCapacitor <: Component

Similar to [ExampleSeriesClawCapacitor](@ref), but the capacitor is teed off a feedline.

Contains hooks `p0` at the feedline input and `p1` at the feedline output, as well as
`p2` at the capacitively coupled output, as well as left-handed versions. (When left-handed hooks
are fused to right-handed hooks, an extra reflection is applied when aligning the hooks—see
[`HandedPointHook`](@ref).)

This component is intended for use in demonstrations.

# Parameters

  - `name = "claw"`: Name of component
  - `feedline_length = 300μm`: Total length of feedline
  - `feedline_style = Paths.CPW(10μm, 6μm)`: Style of feedline path
  - `input_length = 20μm`: Length of "input" path between edge of feedline and claw
  - `input_style = Paths.CPW(10μm, 6μm)`: Style of "input" path
  - `inner_cap_width = 20μm`: Width (short dimension, usually) of inner capacitor pad
  - `inner_cap_length = 200μm`: Length (long dimension) of inner capacitor pad
  - `claw_inner_gap = 5μm`: Gap between claw and inner pad
  - `claw_width = 10μm`: Width of claw metal trace
  - `claw_outer_gap = 20μm`: Outer gap around claw
  - `output_style = Paths.CPW(10μm, 6μm)`: Style of output path
  - `rounding = 2μm`: Rounding radius applied to the capacitor
  - `bridge = nothing`: `CoordinateSystem` holding the air bridge geometry for the feedline and
    input

# Hooks

  - `p0`: Feedline input
  - `p1`: Feedline output
  - `p2`: Capacitively coupled output
  - `p0_lh`: Feedline input (left-handed)
  - `p1_lh`: Feedline output (left-handed)
  - `p2_lh`: Capacitively coupled output (left-handed)
"""
@compdef struct ExampleShuntClawCapacitor <: Component
    name = "claw"
    feedline_length = 300μm
    feedline_style = Paths.CPW(10μm, 6μm)
    input_length = 20μm
    input_style = Paths.CPW(10μm, 6μm)
    inner_cap_width = 20μm
    inner_cap_length = 200μm
    claw_inner_gap = 5μm
    claw_width = 10μm
    claw_outer_gap = 20μm
    output_style = Paths.CPW(10μm, 10μm)
    rounding = 2μm
    bridge = nothing
end

function SchematicDrivenLayout._geometry!(
    cs::CoordinateSystem,
    cc::ExampleShuntClawCapacitor
)
    pa, tap = _paths(cc)
    place!(cs, pa)
    place!(cs, tap)

    claw_cutout = _series_claw(cc)
    # Align claw below tap before attaching bridge, which may extend below tap
    claw_cutout = Align.below(claw_cutout, tap; centered=true)
    !isnothing(cc.bridge) && attach!(tap, sref(cc.bridge), pathlength(tap[end]) / 2)
    ms = MeshSized(critical_dimension(cc))
    place!(cs, ms(claw_cutout), METAL_NEGATIVE)

    return cs
end

# Helper function to generate paths, used in both `_geometry!` and `hooks`
function _paths(cc::ExampleShuntClawCapacitor)
    (; feedline_style, feedline_length, input_style, input_length, rounding, bridge) = cc
    pa = Path(metadata=METAL_NEGATIVE, name=uniquename("$(cc.name)feed"))
    straight!(pa, feedline_length / 2 - Paths.extent(input_style), feedline_style)
    !isnothing(bridge) && attach!(pa, sref(bridge), zero(feedline_length))
    tap = tap!(pa, input_style)
    straight!(pa, feedline_length - pathlength(pa))
    !isnothing(bridge) && attach!(pa, sref(bridge), pathlength(pa[end]))
    straight!(tap, input_length - rounding) # Extend tap, leave room for rounding later
    return pa, tap
end

function SchematicDrivenLayout.hooks(cc::ExampleShuntClawCapacitor)
    (; inner_cap_width, claw_inner_gap, claw_width, claw_outer_gap, rounding) = cc
    pa, tap = _paths(cc) # Generate another copy of the paths so we can use their hooks
    straight!(
        tap, # Extend tap to get to the connection point on the other side
        inner_cap_width + 2 * (rounding + claw_outer_gap + claw_width + claw_inner_gap)
    )
    return merge(hooks(pa), (; p2=p1_hook(tap), p2_lh=p1_hook(tap, false)))
end

end # module
