# Single-transmon SolidModel workload: the geometry of `examples/SingleTransmon` without that
# example's Palace post-processing dependencies. Small enough (~1 min) to run on every
# benchmark invocation as a smoke test and as a same-machine reference for the QPU17 timings.

using DeviceLayout, DeviceLayout.SolidModels, DeviceLayout.PreferredUnits
using DeviceLayout.SchematicDrivenLayout, DeviceLayout.SchematicDrivenLayout.ExamplePDK
using .ExamplePDK.LayerVocabulary, .ExamplePDK.Transmons, .ExamplePDK.ReadoutResonators
import .ExamplePDK: add_bridges!
import .ExamplePDK.SimpleJunctions: ExampleSimpleJunction

"""
    single_transmon_setup() -> (floorplan, target)

Plan the single-transmon schematic (rectangle transmon, clawed meander readout, feedline
with two lumped ports) and return it with the single-chip `SolidModelTarget`.
"""
function single_transmon_setup()
    reset_uniquename!()
    cpw_width = 10μm
    cpw_gap = 6μm
    PATH_STYLE = Paths.SimpleCPW(cpw_width, cpw_gap)
    BRIDGE_STYLE = ExamplePDK.bridge_geometry(PATH_STYLE)
    cap_length = 620μm
    cap_width = 24μm
    cap_gap = 30μm
    total_length = 5000μm
    coupling_gap = 5μm
    meander_turn_count = 4
    bend_radius = 50μm
    hanger_length = 500μm
    grasp_width = cap_width + 2 * cap_gap
    arm_length = 428μm
    total_y_length =
        arm_length +
        coupling_gap +
        Paths.extent(PATH_STYLE) +
        hanger_length +
        (3 + meander_turn_count * 2) * bend_radius

    qubit = ExampleRectangleTransmon(;
        jj_template=ExampleSimpleJunction(),
        name="qubit",
        cap_length,
        cap_gap,
        cap_width
    )
    rres = ExampleClawedMeanderReadout(;
        name="rres",
        coupling_length=400μm,
        coupling_gap,
        total_length,
        shield_width=24μm,
        claw_trace=10μm,
        claw_length=136μm,
        claw_gap=6μm,
        grasp_width,
        meander_turn_count,
        total_y_length,
        hanger_length,
        bend_radius,
        bridge=BRIDGE_STYLE
    )
    readout_length = 2700μm
    p_readout = Path(
        Point(0μm, 0μm);
        α0=π / 2,
        name="p_ro",
        metadata=LayerVocabulary.METAL_NEGATIVE
    )
    straight!(p_readout, readout_length / 2, PATH_STYLE)
    straight!(p_readout, readout_length / 2, PATH_STYLE)
    csport = CoordinateSystem(uniquename("port"), nm)
    render!(
        csport,
        only_simulated(WithDirection(centered(Rectangle(cpw_width, cpw_width)))),
        LayerVocabulary.PORT
    )
    attach!(p_readout, sref(csport), cpw_width, i=1)
    attach!(p_readout, sref(csport, rot=180°), readout_length / 2 - cpw_width, i=2)

    g = SchematicGraph("single-transmon")
    qubit_node = add_node!(g, qubit)
    rres_node = fuse!(g, qubit_node, rres)
    p_readout_node = add_node!(g, p_readout)
    attach!(g, p_readout_node, rres_node => :feedline, 0mm, location=1)
    floorplan = plan(g; log_dir=mktempdir())
    add_bridges!(floorplan, BRIDGE_STYLE, spacing=300μm)

    substrate_x = 4mm
    substrate_y = 3.7mm
    center_xyz = DeviceLayout.center(floorplan)
    chip = centered(Rectangle(substrate_x + 10μm, substrate_y + 10μm), on_pt=center_xyz)
    sim_area = centered(Rectangle(substrate_x, substrate_y), on_pt=center_xyz)
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.SIMULATED_AREA)
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.WRITEABLE_AREA)
    render!(floorplan.coordinate_system, chip, LayerVocabulary.CHIP_AREA)
    check!(floorplan)

    target = ExamplePDK.singlechip_solidmodel_target("port_1", "port_2", "lumped_element")
    return floorplan, target
end
