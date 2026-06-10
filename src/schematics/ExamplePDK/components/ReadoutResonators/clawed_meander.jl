import .ExamplePDK: tap!
import .ExamplePDK.Transmons: ExampleRectangleTransmon

"""
    struct ExampleClawedMeanderReadout <: Component

Readout resonator consisting of a meander with short and claw-capacitor terminations.

This component is intended for use in demonstrations with `ExampleRectangleTransmon`.

# Parameters

  - `name`: Name of component
  - `resonator_style`: Resonator CPW style
  - `total_length`: Total length of resonator
  - `coupling_length`: Length of coupling section
  - `coupling_gap`: Width of ground plane between coupling section and coupled line
  - `bend_radius`: Meander bend radius
  - `meander_turn_count`: Number of meander turns
  - `total_y_length`: Total y length from top hook to bottom hook
  - `hanger_length`: Length of hanger section between coupling section and meander
  - `shield_width`: Width of claw capacitor ground plane shield
  - `claw_trace`: Claw trace width
  - `claw_length`: Claw finger length
  - `claw_gap`: Claw capacitor gap
  - `grasp_width`: Width between inner edges of ground plane shield
  - `bridge = nothing`: `CoordinateSystem` containing a bridge to place along the resonator; if
    `nothing`, no bridge is attached. Define decorations at the device level and share the same
    instance across components.
"""
@compdef struct ExampleClawedMeanderReadout <: Component
    name               = "rres"
    resonator_style    = DeviceLayout.Paths.SimpleCPW(10.0μm, 6.0μm)
    total_length       = 5000μm
    coupling_length    = 200μm
    coupling_gap       = 5μm
    bend_radius        = 50μm
    meander_turn_count = 5
    total_y_length     = 1656μm # from top hook to bottom hook
    hanger_length      = 500μm
    shield_width       = 2μm
    claw_trace         = 32μm
    claw_length        = 160μm
    claw_gap           = 6μm
    grasp_width        = 84μm
    bridge             = nothing
end

function SchematicDrivenLayout._geometry!(
    cs::CoordinateSystem,
    rres::ExampleClawedMeanderReadout
)
    (;
        resonator_style,
        total_length,
        coupling_length,
        coupling_gap,
        bend_radius,
        meander_turn_count,
        total_y_length,
        hanger_length,
        shield_width,
        claw_trace,
        claw_length,
        claw_gap,
        grasp_width,
        bridge
    ) = rres
    # Center vertical axis is midpoint of coupling section
    pres = Path(
        Point(
            -coupling_length / 2,
            -coupling_gap - resonator_style.gap - resonator_style.trace / 2
        ),
        α0=0°
    )
    n_bends = 3 + 2 * meander_turn_count # number of 90 degree bends
    arm_length = (
        total_y_length - hanger_length - n_bends * bend_radius - coupling_gap -
        resonator_style.gap - resonator_style.trace / 2 - shield_width - 2 * claw_gap -
        claw_trace
    )

    # Length of straight sections in meander
    straight_length =
        (
            total_length - 3 * coupling_length / 2 - n_bends * pi * bend_radius / 2 -
            arm_length - hanger_length
        ) / meander_turn_count

    ### CPW path
    straight!(pres, coupling_length, resonator_style)
    turn!(pres, -90°, bend_radius)
    straight!(pres, hanger_length)
    !isnothing(bridge) &&
        attach!(pres, CoordinateSystemReference(bridge), hanger_length / 2)
    turn!(pres, -90°, bend_radius)
    # Center of the straight section of meander lines up with coupling midpoint (and claw)
    straight!(pres, straight_length / 2 + coupling_length / 2)
    turn!(pres, 180°, bend_radius)

    # Start the meander with a full straight section
    meander_length =
        (meander_turn_count - 1) * (straight_length + pi * bend_radius) +
        straight_length / 2 - bend_radius
    meander!(pres, meander_length, straight_length, bend_radius, -180°)
    turn!(pres, -90°, bend_radius)
    straight!(pres, arm_length)
    !isnothing(bridge) && attach!(pres, CoordinateSystemReference(bridge), arm_length / 2)

    ### Claw
    arm_trace = resonator_style.trace
    pt0 = p1(pres.nodes[end].seg)

    claw_hole1 = Rectangle(arm_trace, claw_gap) + pt0 + Point(-arm_trace / 2, -claw_gap)

    claw_hole2 = Rectangle(
        grasp_width + 2 * shield_width + 4 * claw_gap + 2 * claw_trace,
        claw_trace + 2 * claw_gap
    )
    claw_hole2 = Align.flushtop(claw_hole2, claw_hole1, centered=true)

    claw_hole3 = Rectangle(claw_trace + 2 * claw_gap, shield_width + claw_length + claw_gap)
    claw_hole3 = Align.flushleft(Align.below(claw_hole3, claw_hole2), claw_hole2)

    claw_hole4 = Align.flushright(claw_hole3, claw_hole2)

    claw1 = Rectangle(arm_trace, claw_gap)
    claw1 = Align.flushtop(claw1, claw_hole1, centered=true)

    claw2 = Rectangle(
        grasp_width + 2 * shield_width + 2 * claw_gap + 2 * claw_trace,
        claw_trace
    )
    claw2 = Align.below(claw2, claw1, centered=true)

    claw3 = Rectangle(claw_trace, claw_gap + shield_width + claw_length)
    claw3 = Align.flushleft(Align.below(claw3, claw2), claw2)

    claw4 = Align.flushright(claw3, claw2)

    claw = difference2d(
        [claw_hole1, claw_hole2, claw_hole3, claw_hole4],
        [claw1, claw2, claw3, claw4]
    )

    render!.(cs, [pres, MeshSized(2 * claw_gap)(claw)], METAL_NEGATIVE)

    # This component creates narrow regions defined by the gap between it and others
    # We should explicitly set mesh sizing since meshing doesn't use proximity
    ### Mesh control on shield ground plane strip
    shield1 = Align.below(
        Rectangle(grasp_width + 2 * shield_width, shield_width),
        claw_hole2,
        centered=true
    )
    shield2 = Align.flushleft(
        Align.below(Rectangle(shield_width, claw_length + claw_gap), shield1),
        shield1
    )
    shield3 = Align.flushright(
        Align.below(Rectangle(shield_width, claw_length + claw_gap), shield1),
        shield1
    )
    shield = union2d([shield1, shield2, shield3])
    render!(cs, MeshSized(2 * shield_width)(only_simulated(shield)), MESH_CONTROL)

    ### Mesh control on feedline coupler ground plane strip
    strip = Align.above(Rectangle(coupling_length, coupling_gap), pres[1], centered=true)
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
    qubit_hook = PointHook(Point(zero(rres.claw_trace), -rres.total_y_length), 90°)
    feedline_hook = PointHook(zero(Point{typeof(rres.claw_trace)}), -90°)
    return (; qubit=qubit_hook, feedline=feedline_hook)
end

SchematicDrivenLayout.matching_hooks(
    ::ExampleRectangleTransmon,
    ::ExampleClawedMeanderReadout
) = (:readout, :qubit)
SchematicDrivenLayout.matching_hooks(
    ::ExampleClawedMeanderReadout,
    ::ExampleRectangleTransmon
) = (:qubit, :readout)
