
module SingleTransmonExperimental
# Using a module to let us cleanly include file in test script without worrying about namespaces

using FileIO, JSON, JSONSchema
using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
import DeviceLayout.SolidModelsExperimental: Ground, LayerRef, Locator, LumpedPort, Terminal
import .SchematicDrivenLayout.ExamplePDKExperimental
import .ExamplePDKExperimental: SINGLECHIP_STACK, add_bridges!, add_wave_ports!
using .ExamplePDKExperimental.TransmonsExperimental,
    .ExamplePDKExperimental.ReadoutResonatorsExperimental
import .ExamplePDKExperimental.SimpleJunctionsExperimental: ExampleSimpleJunction

"""
    single_transmon(
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
        save_mesh::Bool=false,
        save_gds::Bool=false,
        mesh_order=2,
        dir=pwd())

Generate a SolidModel, its metadata, and optionally a mesh for a single transmon design,
using a rectangular transmon island and claw resonator.

The metadata JSON file, the schematic log, and the optional mesh and GDS files are written to
`dir`. Returns the schematic, the `SolidModel`, and the path of the metadata file.
"""
function single_transmon(;
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
    save_mesh::Bool=false,
    save_gds::Bool=false,
    mesh_order=2,
    dir=pwd()
)
    #### Reset name counter for consistency within a Julia session
    reset_uniquename!()

    #### Assemble schematic graph
    ### Compute additional/implicit parameters
    cpw_width = 10μm
    cpw_gap = 6μm
    PATH_STYLE = Paths.SimpleCPW(cpw_width, cpw_gap)
    BRIDGE_STYLE = ExamplePDKExperimental.bridge_geometry(PATH_STYLE)
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
        metadata=LayerRef(:metal_negative)
    )
    straight!(p_readout, readout_length / 2, PATH_STYLE)
    straight!(p_readout, readout_length / 2, PATH_STYLE)
    # Name the feedline's trace as a terminal, at the midpoint where no bridge sits
    cs_feedline = CoordinateSystem(uniquename("feedline"), nm)
    place!(cs_feedline, Locator(0μm, 0μm), Terminal(:metal, "feedline"))
    attach!(p_readout, sref(cs_feedline), 0μm, i=2)

    # Readout lumped ports - squares on CPW trace, one at each end
    if !wave_ports
        # Each port has its own coordinate system, since a structure referenced twice
        # would carry the same locator twice
        for (i, (rot, location)) in enumerate(((0°, cpw_width), (180°, readout_length / 2 - cpw_width)))
            csport = CoordinateSystem(uniquename("port"), nm)
            place!(
                csport,
                centered(Rectangle(cpw_width, cpw_width)) |> WithDirection(0°),
                LayerRef(:port)
            )
            place!(csport, Locator(0μm, 0μm), LumpedPort(:port, "port_$i"))
            # Attach with port center `cpw_width` from the end (instead of `cpw_width/2`) to avoid corner effects
            attach!(p_readout, sref(csport, rot=rot), location, i=i)
        end
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
    attach!(g, p_readout_node, rres_node => :feedline, 0mm, location=:right)

    #### Create the schematic (position the components)
    floorplan = plan(g; log_dir=dir)
    add_bridges!(floorplan, BRIDGE_STYLE, spacing=300μm) # Add bridges to paths

    #### Prepare solid model
    # Specify the extent of the simulation domain.
    substrate_x = 4mm # wave port domain boundary needs to touch the readout line
    substrate_y = 3.7mm

    center_xyz = DeviceLayout.center(floorplan)
    chip = centered(Rectangle(substrate_x + 10μm, substrate_y + 10μm), on_pt=center_xyz)
    sim_area = centered(Rectangle(substrate_x, substrate_y), on_pt=center_xyz)

    # Define bounds for bounding simulation box
    place!(floorplan.coordinate_system, sim_area, LayerRef(:simulated_area))
    # The target cuts :metal_negative from the writeable area and adds :junction_leads
    place!(floorplan.coordinate_system, sim_area, LayerRef(:metal))
    # Mark the ground plane, inside the writeable area near its corner
    place!(
        floorplan.coordinate_system,
        Locator(sim_area.ll + Point(10μm, 10μm)),
        Ground(:metal)
    )
    # Define rectangle that gets extruded to generate substrate volume
    place!(floorplan.coordinate_system, chip, LayerRef(:substrate))

    # Add wave ports
    wave_ports && add_wave_ports!(floorplan, [p_readout_node], sim_area, 0.6mm)

    check!(floorplan)

    tech = ExamplePDKExperimental.singlechip_solidmodel_target(; wave_ports)
    sm = SolidModel("test", overwrite=true)

    # Adjust mesh_scale to increase the resolution of the mesh, < 1 will result in greater
    # resolution near edges of the geometry.
    SolidModels.set_gmsh_option("General.Verbosity", 1)
    SolidModels.mesh_order(mesh_order)
    metadata = render!(sm, floorplan, tech)
    metadata_path = joinpath(dir, "single_transmon_metadata.json")
    open(metadata_path, "w") do io
        return JSON.print(io, metadata, 4)
    end

    if save_mesh
        # SolidModels.gmsh.option.set_number("General.NumThreads", 1) # Force single-threaded (deterministic) meshing
        SolidModels.gmsh.model.mesh.generate(3) # runs without error
        save(joinpath(dir, "single_transmon.msh2"), sm)
    end

    if save_gds
        # Render the artwork to GDS as well; layers without a `gds_meta` are skipped
        c = Cell("single_transmon", nm)
        render!(c, flatten(floorplan.coordinate_system), SINGLECHIP_STACK)
        save(joinpath(dir, "single_transmon.gds"), c)
    end
    return floorplan, sm, metadata_path
end

"""
    configfile(metadata_path; palace_build=nothing, solver_order=2, amr=0, wave_ports=false)

Given the path of the metadata JSON file written by [`single_transmon`](@ref), assemble a
dictionary defining a configuration file for use within Palace.

  - `metadata_path`: Path to the metadata JSON file of the solid model, which records its
    physical groups and the port selections and directions. The configuration reads the mesh
    from, and writes Palace's output to, the directory of this file.
  - `palace_build = nothing`: Path to a Palace build directory, used to perform validation of
    the configuration file. If not present, no validation is performed.
  - `solver_order = 2`: Finite element order (degree) for the solver. Palace supports arbitrary
    high-order spaces.
  - `amr = 0`: Maximum number of adaptive mesh refinement (AMR) iterations.
"""
function configfile(
    metadata_path::AbstractString;
    palace_build=nothing,
    solver_order=2,
    amr=0,
    wave_ports=false
)
    metadata = JSON.parsefile(metadata_path)
    # single_transmon writes the mesh next to the metadata
    dir = dirname(metadata_path)
    tags(pg_names) = [metadata["physical_groups"][pg_name]["tag"] for pg_name in pg_names]
    layer_attributes(layer_name) = tags(metadata["layers"][layer_name]["pgs"])
    port = name -> metadata["ports"][name]
    port_attributes(name) = tags(port(name)["pgs"])

    config = Dict(
        "Problem" => Dict(
            "Type" => "Eigenmode",
            "Verbose" => 2,
            "Output" => joinpath(dir, "postpro/single-transmon")
        ),
        "Model" => Dict(
            "Mesh" => joinpath(dir, "single_transmon.msh2"),
            "L0" => 1e-6, # um is Palace default; record it anyway
            "Refinement" => Dict(
                "MaxIts" => amr # Nonzero to enable AMR
            )
        ),
        "Domains" => Dict(
            "Materials" => [
                Dict(
                    # Vacuum
                    "Attributes" => layer_attributes("vacuum"),
                    "Permeability" => 1.0,
                    "Permittivity" => 1.0
                ),
                Dict(
                    # Sapphire
                    "Attributes" => layer_attributes("substrate"),
                    "Permeability" => [0.99999975, 0.99999975, 0.99999979],
                    "Permittivity" => [9.3, 9.3, 11.5],
                    "LossTan" => [3.0e-5, 3.0e-5, 8.6e-5],
                    "MaterialAxes" =>
                        [[0.8, 0.6, 0.0], [-0.6, 0.8, 0.0], [0.0, 0.0, 1.0]]
                )
            ],
            "Postprocessing" => Dict(
                "Energy" =>
                    [Dict("Index" => 1, "Attributes" => layer_attributes("substrate"))]
            )
        ),
        "Boundaries" => Dict(
            "PEC" => Dict("Attributes" => layer_attributes("metal")),
            "Absorbing" => Dict(
                "Attributes" => layer_attributes("exterior_boundary"),
                "Order" => 1
            ),
            (
                wave_ports ?
                (
                    "WavePort" => [
                        Dict("Index" => 1, "Attributes" => port_attributes("p_ro_wave_port_1")),
                        Dict("Index" => 2, "Attributes" => port_attributes("p_ro_wave_port_2"))
                    ],
                ) : ()
            )...,
            "LumpedPort" => [
                (
                    wave_ports ? () :
                    (
                        Dict(
                            "Index" => 1,
                            "Attributes" => port_attributes("p_ro.port_1"),
                            "R" => 50,
                            "Direction" => port("p_ro.port_1")["direction"]
                        ),
                        Dict(
                            "Index" => 2,
                            "Attributes" => port_attributes("p_ro.port_2"),
                            "R" => 50,
                            "Direction" => port("p_ro.port_2")["direction"]
                        )
                    )
                )...,
                Dict(
                    "Index" => 3,
                    "Attributes" => port_attributes("qubit.junction"),
                    "L" => 14.860e-9,
                    "C" => 5.5e-15,
                    "Direction" => port("qubit.junction")["direction"]
                )
            ]
        ),
        "Solver" => Dict(
            "Order" => solver_order,
            "Eigenmode" =>
                Dict("N" => 2, "Tol" => 1.0e-6, "Target" => 2.5, "Save" => 2),
            "Linear" => Dict("Type" => "Default", "Tol" => 1.0e-7, "MaxIts" => 500)
        )
    )

    if !isnothing(palace_build)
        # Load the json schema and validate the configuration
        schema_dir = joinpath(palace_build, "bin", "schema")
        schema = Schema(
            JSON.parsefile(joinpath(schema_dir, "config-schema.json"));
            parent_dir=schema_dir
        )
        validate(schema, config)
    end

    return config
end

end # module
