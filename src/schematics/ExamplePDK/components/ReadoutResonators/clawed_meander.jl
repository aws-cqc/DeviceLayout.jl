import DeviceLayout: flushtop, flushleft, flushright, below, above

import .ExamplePDK: filter_params, tap!
import .ExamplePDK.Transmons: ExampleRectangleTransmon

"""
    struct ExampleClawedMeanderReadout <: Component

Readout resonator consisting of a meander with short and claw-capacitor terminations.

This component is intended for use in demonstrations with `ExampleRectangleTransmon`.

# Parameters

  - `name`: Name of component
  - `style`: Resonator CPW style
  - `total_length`: Total length of resonator
  - `coupling_length`: Length of coupling section
  - `coupling_gap`: Width of ground plane between coupling section and coupled line
  - `bend_radius`: Meander bend radius
  - `n_meander_turns`: Number of meander turns
  - `total_height`: Total height from top hook to bottom hook
  - `hanger_length`: Length of hanger section between coupling section and meander
  - `w_shield`: Width of claw capacitor ground plane shield
  - `w_claw`: Claw trace width
  - `l_claw`: Claw finger length
  - `claw_gap`: Claw capacitor gap
  - `w_grasp`: Width between inner edges of ground plane shield
  - `bridge`: `CoordinateSystem` containing a bridge
"""
@compdef struct ExampleClawedMeanderReadout <: Component
    name            = "rres"
    style           = DeviceLayout.Paths.SimpleCPW(10.0μm, 6.0μm)
    total_length    = 5000μm
    coupling_length = 200μm
    coupling_gap    = 5μm
    bend_radius     = 50μm
    n_meander_turns = 5
    total_height    = 1656μm # from top hook to bottom hook
    hanger_length   = 500μm
    w_shield        = 2μm
    w_claw          = 32μm
    l_claw          = 160μm
    claw_gap        = 6μm
    w_grasp         = 84μm
    bridge          = CoordinateSystem("rresbridge", nm)
end

function SchematicDrivenLayout._geometry!(
    cs::CoordinateSystem,
    rres::ExampleClawedMeanderReadout
)
    (;
        style,
        total_length,
        coupling_length,
        coupling_gap,
        bend_radius,
        n_meander_turns,
        total_height,
        hanger_length,
        w_shield,
        w_claw,
        l_claw,
        claw_gap,
        w_grasp,
        bridge
    ) = parameters(rres)
    # Center vertical axis is midpoint of coupling section
    pres = Path(
        Point(-coupling_length / 2, -coupling_gap - style.gap - style.trace / 2),
        α0=0°
    )
    n_bends = 3 + 2 * n_meander_turns # number of 90 degree bends
    arm_length = (
        total_height - hanger_length - n_bends * bend_radius - coupling_gap - style.gap - style.trace / 2 - w_shield - 2 * claw_gap - w_claw
    )

    # Length of straight sections in meander
    straight_length =
        (
            total_length - 3 * coupling_length / 2 - n_bends * pi * bend_radius / 2 -
            arm_length - hanger_length
        ) / n_meander_turns

    ### CPW path
    straight!(pres, coupling_length, style)
    turn!(pres, -90°, bend_radius)
    straight!(pres, hanger_length)
    attach!(pres, CoordinateSystemReference(bridge), hanger_length / 2)
    turn!(pres, -90°, bend_radius)
    # Center of the straight section of meander lines up with coupling midpoint (and claw)
    straight!(pres, straight_length / 2 + coupling_length / 2)
    turn!(pres, 180°, bend_radius)

    # Start the meander with a full straight section
    meander_length =
        (n_meander_turns - 1) * (straight_length + pi * bend_radius) + straight_length / 2 -
        bend_radius
    meander!(pres, meander_length, straight_length, bend_radius, -180°)
    turn!(pres, -90°, bend_radius)
    straight!(pres, arm_length)
    attach!(pres, CoordinateSystemReference(bridge), arm_length / 2)

    ### Claw
    arm_trace = style.trace
    pt0 = p1(pres.nodes[end].seg)

    claw_hole1 = Rectangle(arm_trace, claw_gap) + pt0 + Point(-arm_trace / 2, -claw_gap)

    claw_hole2 =
        Rectangle(w_grasp + 2 * w_shield + 4 * claw_gap + 2 * w_claw, w_claw + 2 * claw_gap)
    claw_hole2 = flushtop(claw_hole2, claw_hole1, centered=true)

    claw_hole3 = Rectangle(w_claw + 2 * claw_gap, w_shield + l_claw + claw_gap)
    claw_hole3 = flushleft(below(claw_hole3, claw_hole2), claw_hole2)

    claw_hole4 = flushright(claw_hole3, claw_hole2)

    claw1 = Rectangle(arm_trace, claw_gap)
    claw1 = flushtop(claw1, claw_hole1, centered=true)

    claw2 = Rectangle(w_grasp + 2 * w_shield + 2 * claw_gap + 2 * w_claw, w_claw)
    claw2 = below(claw2, claw1, centered=true)

    claw3 = Rectangle(w_claw, claw_gap + w_shield + l_claw)
    claw3 = flushleft(below(claw3, claw2), claw2)

    claw4 = flushright(claw3, claw2)

    claw = difference2d(
        [claw_hole1, claw_hole2, claw_hole3, claw_hole4],
        [claw1, claw2, claw3, claw4]
    )

    render!.(cs, [pres, MeshSized(2 * claw_gap)(claw)], METAL_NEGATIVE)

    # This component creates narrow regions defined by the gap between it and others
    # For now we should explicitly set mesh sizing since meshing doesn't use proximity
    ### Mesh control on shield ground plane strip
    shield1 = below(Rectangle(w_grasp + 2 * w_shield, w_shield), claw_hole2, centered=true)
    shield2 = flushleft(below(Rectangle(w_shield, l_claw + claw_gap), shield1), shield1)
    shield3 = flushright(below(Rectangle(w_shield, l_claw + claw_gap), shield1), shield1)
    shield = union2d([shield1, shield2, shield3])
    render!(cs, MeshSized(2 * w_shield)(only_simulated(shield)), MESH_CONTROL)

    ### Mesh control on feedline coupler ground plane strip
    strip = above(Rectangle(coupling_length, coupling_gap), pres[1], centered=true)
    render!(cs, MeshSized(2 * coupling_gap)(only_simulated(strip)), MESH_CONTROL)
    return cs
end

"""
    hooks(rres::ExampleClawedMeanderReadout)

`Hook`s for attaching a readout resonator claw to a qubit and coupling section to a feedline.

  - `qubit`: The "palm" of the claw on the outside edge of the "shield". Matches
    `(eq::ExampleRectangleTransmon) => :rres`.
  - `feedline`: A distance `coupling_gap` from the edge of the ground plane, vertically aligned
    with the claw.
"""
function SchematicDrivenLayout.hooks(rres::ExampleClawedMeanderReadout)
    qubit_hook = PointHook(Point(zero(rres.w_claw), -rres.total_height), 90°)
    feedline_hook = PointHook(zero(Point{typeof(rres.w_claw)}), -90°)
    return (qubit=qubit_hook, feedline=feedline_hook)
end

SchematicDrivenLayout.matching_hooks(
    ::ExampleRectangleTransmon,
    ::ExampleClawedMeanderReadout
) = (:readout, :qubit)
SchematicDrivenLayout.matching_hooks(
    ::ExampleClawedMeanderReadout,
    ::ExampleRectangleTransmon
) = (:qubit, :readout)
