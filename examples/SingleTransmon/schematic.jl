# Schematic and `SolidModelTarget` for the single-transmon example. This file depends only on
# DeviceLayout, so it can be included on its own (as the SolidModel benchmarks do) without the
# Palace post-processing dependencies of `SingleTransmon.jl`, which includes it.

using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
import DeviceLayout.SchematicDrivenLayout.ExamplePDK
import DeviceLayout.SchematicDrivenLayout.ExamplePDK:
    LayerVocabulary, add_bridges!, add_wave_ports!
using .ExamplePDK.Transmons, .ExamplePDK.ReadoutResonators
import .ExamplePDK.SimpleJunctions: ExampleSimpleJunction

"""
    single_transmon_schematic(;
        shield_width=2μm,
        claw_gap=6μm,
        claw_trace=34μm,
        claw_length=121μm,
        cap_width=24μm,
        cap_length=620μm,
        cap_gap=30μm,
        total_length=5000μm,
        meander_turn_count=5,
        hanger_length=500μm,
        bend_radius=50μm,
        wave_ports::Bool=false,
        log_dir="build") -> (floorplan, target)

Plan the single-transmon schematic (rectangular transmon island, claw resonator, readout
feedline with lumped or wave ports) and return it with the single-chip `SolidModelTarget`
that retains the port and lumped-element groups. The schematic's log is written to `log_dir`.
"""
function single_transmon_schematic(;
    shield_width=2μm,
    claw_gap=6μm,
    claw_trace=34μm,
    claw_length=121μm,
    cap_width=24μm,
    cap_length=620μm,
    cap_gap=30μm,
    total_length=5000μm,
    meander_turn_count=5,
    hanger_length=500μm,
    bend_radius=50μm,
    wave_ports::Bool=false,
    log_dir="build"
)
    #### Reset name counter for consistency within a Julia session
    reset_uniquename!()

    #### Assemble schematic graph
    ### Compute additional/implicit parameters
    cpw_width = 10μm
    cpw_gap = 6μm
    PATH_STYLE = Paths.SimpleCPW(cpw_width, cpw_gap)
    BRIDGE_STYLE = ExamplePDK.bridge_geometry(PATH_STYLE)
    coupling_gap = 5μm
    grasp_width = cap_width + 2 * cap_gap
    arm_length = 428μm # straight length from meander exit to claw
    total_y_length =
        arm_length +
        coupling_gap +
        Paths.extent(PATH_STYLE) +
        hanger_length +
        (3 + meander_turn_count * 2) * bend_radius
    ### Create abstract components
    ## Transmon
    qubit = ExampleRectangleTransmon(;
        jj_template=ExampleSimpleJunction(),
        name="qubit",
        cap_length,
        cap_gap,
        cap_width
    )
    ## Resonator
    rres = ExampleClawedMeanderReadout(;
        name="rres",
        coupling_length=400μm,
        coupling_gap,
        total_length,
        shield_width,
        claw_trace,
        claw_length,
        claw_gap,
        grasp_width,
        meander_turn_count,
        total_y_length,
        hanger_length,
        bend_radius,
        bridge=BRIDGE_STYLE
    )
    ## Readout path
    readout_length = wave_ports ? 4mm : 2700μm
    p_readout = Path(
        Point(0μm, 0μm);
        α0=π / 2,
        name="p_ro",
        metadata=LayerVocabulary.METAL_NEGATIVE
    )
    straight!(p_readout, readout_length / 2, PATH_STYLE)
    straight!(p_readout, readout_length / 2, PATH_STYLE)

    # Readout lumped ports - squares on CPW trace, one at each end
    if !wave_ports
        csport = CoordinateSystem(uniquename("port"), nm)
        render!(
            csport,
            only_simulated(WithDirection(centered(Rectangle(cpw_width, cpw_width)))),
            LayerVocabulary.PORT
        )
        # Attach with port center `cpw_width` from the end (instead of `cpw_width/2`) to avoid corner effects
        attach!(p_readout, sref(csport), cpw_width, i=1) # @ start
        attach!(p_readout, sref(csport, rot=180°), readout_length / 2 - cpw_width, i=2) # @ end
    end

    #### Build schematic graph
    g = SchematicGraph("single-transmon")
    qubit_node = add_node!(g, qubit)
    rres_node = fuse!(g, qubit_node, rres)
    # Equivalent to `fuse!(g, qubit_node=>:readout, rres=>:qubit)`
    # because `matching_hooks` was implemented for that component pair
    p_readout_node = add_node!(g, p_readout)

    ## Attach resonator to feedline
    # Instead of `fuse!` we use a schematic-based `attach!` method to place it along the path
    # Syntax is a mix of `fuse!` and how we attached the ports above
    attach!(g, p_readout_node, rres_node => :feedline, 0mm, location=1)

    #### Create the schematic (position the components)
    floorplan = plan(g; log_dir)
    add_bridges!(floorplan, BRIDGE_STYLE, spacing=300μm) # Add bridges to paths

    #### Prepare solid model
    # Specify the extent of the simulation domain.
    substrate_x = 4mm # wave port domain boundary needs to touch the readout line
    substrate_y = 3.7mm

    center_xyz = DeviceLayout.center(floorplan)
    chip = centered(Rectangle(substrate_x + 10μm, substrate_y + 10μm), on_pt=center_xyz)
    sim_area = centered(Rectangle(substrate_x, substrate_y), on_pt=center_xyz)

    # Define bounds for bounding simulation box
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.SIMULATED_AREA)
    # postrendering operations in solidmodel target define metal = (WRITEABLE_AREA - METAL_NEGATIVE) + METAL_POSITIVE
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.WRITEABLE_AREA)
    # Define rectangle that gets extruded to generate substrate volume
    render!(floorplan.coordinate_system, chip, LayerVocabulary.CHIP_AREA)

    # Add wave ports
    wave_ports && add_wave_ports!(
        floorplan,
        [p_readout_node],
        sim_area,
        0.6mm,
        LayerVocabulary.WAVE_PORT
    )

    check!(floorplan)

    # Need to pass generated physical group names so they can be retained
    target = if wave_ports
        ExamplePDK.singlechip_solidmodel_target("wave_port_1", "wave_port_2", "lumped_element")
    else
        ExamplePDK.singlechip_solidmodel_target("port_1", "port_2", "lumped_element")
    end
    return floorplan, target
end
