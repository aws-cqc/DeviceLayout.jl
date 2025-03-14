
module SingleTransmon
# Using a module to let us cleanly include file in test script without worrying about namespaces

using FileIO, CSV, DataFrames, JSON, JSONSchema
using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits
import .SchematicDrivenLayout.ExamplePDK
import .SchematicDrivenLayout.ExamplePDK: LayerVocabulary, L1_TARGET, add_bridges!
using .ExamplePDK.Transmons, .ExamplePDK.ReadoutResonators
import .ExamplePDK.SimpleJunctions: ExampleSimpleJunction
import DeviceLayout: uconvert

using PRIMA

"""
    single_transmon(
        w_shield=2μm,
        claw_gap=6μm,
        w_claw=34μm,
        l_claw=121μm,
        cap_width=24μm,
        cap_length=620μm,
        cap_gap=30μm,
        n_meander_turns=5,
        hanger_length=500μm,
        bend_radius=50μm,
        save_mesh::Bool=false,
        save_gds::Bool=false)

Generate a SolidModel and mesh for a single transmon design, using a rectangular transmon island and claw resonator.
"""
function single_transmon(;
    w_shield=2μm,
    claw_gap=6μm,
    w_claw=34μm,
    l_claw=121μm,
    cap_width=24μm,
    cap_length=620μm,
    cap_gap=30μm,
    total_length=5000μm,
    n_meander_turns=5,
    hanger_length=500μm,
    bend_radius=50μm,
    save_mesh::Bool=false,
    save_gds::Bool=false,
    mesh_order=2
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
    w_grasp = cap_width + 2 * cap_gap
    arm_length = 428μm # straight length from meander exit to claw
    total_height =
        arm_length +
        coupling_gap +
        Paths.extent(PATH_STYLE) +
        hanger_length +
        (3 + n_meander_turns * 2) * bend_radius
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
        w_shield,
        w_claw,
        l_claw,
        claw_gap,
        w_grasp,
        n_meander_turns,
        total_height,
        hanger_length,
        bend_radius,
        bridge=BRIDGE_STYLE
    )
    ## Readout path
    readout_length = 2700μm
    p_readout = Path(
        Point(0μm, 0μm);
        α0=π / 2,
        name="p_ro",
        metadata=LayerVocabulary.METAL_NEGATIVE
    )
    straight!(p_readout, readout_length / 2, PATH_STYLE)
    straight!(p_readout, readout_length / 2, PATH_STYLE)

    # Readout lumped ports - squares on CPW trace, one at each end
    csport = CoordinateSystem(uniquename("port"), nm)
    render!(
        csport,
        only_simulated(centered(Rectangle(cpw_width, cpw_width))),
        LayerVocabulary.PORT
    )
    # Attach with port center `cpw_width` from the end (instead of `cpw_width/2`) to avoid corner effects
    attach!(p_readout, sref(csport), cpw_width, i=1) # @ start
    attach!(p_readout, sref(csport), readout_length / 2 - cpw_width, i=2) # @ end

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
    floorplan = plan(g)
    add_bridges!(floorplan, BRIDGE_STYLE, spacing=300μm) # Add bridges to paths

    #### Prepare solid model
    # Specify the extent of the simulation domain.
    substrate_x = 4mm
    substrate_y = 3.7mm

    center_xyz = DeviceLayout.center(floorplan)
    chip = centered(Rectangle(substrate_x, substrate_y), on_pt=center_xyz)
    sim_area = centered(Rectangle(substrate_x, substrate_y), on_pt=center_xyz)

    # Define bounds for bounding simulation box
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.SIMULATED_AREA)
    # postrendering operations in solidmodel target define metal = (WRITEABLE_AREA - METAL_NEGATIVE) + METAL_POSITIVE
    render!(floorplan.coordinate_system, sim_area, LayerVocabulary.WRITEABLE_AREA)
    # Define rectangle that gets extruded to generate substrate volume
    render!(floorplan.coordinate_system, chip, LayerVocabulary.CHIP_AREA)

    check!(floorplan)

    # Need to pass generated physical group names so they can be retained
    tech = ExamplePDK.singlechip_solidmodel_target("port_1", "port_2", "lumped_element")
    sm = SolidModel("test", overwrite=true)

    # Adjust mesh_scale to increase the resolution of the mesh, < 1 will result in greater
    # resolution near edges of the geometry.
    meshing_parameters = SolidModels.MeshingParameters(
        mesh_scale=1.0,
        α_default=0.9,
        mesh_order=mesh_order,
        options=Dict("General.Verbosity" => 1) # General Gmsh option input
    )
    render!(sm, floorplan, tech, meshing_parameters=meshing_parameters)

    if save_mesh
        # SolidModels.gmsh.option.set_number("General.NumThreads", 1) # Force single-threaded (deterministic) meshing
        SolidModels.gmsh.model.mesh.generate(3) # runs without error
        save(joinpath(@__DIR__, "single_transmon.msh2"), sm)
    end

    if save_gds
        # Render to GDS as well, may be useful to debug SolidModel generation
        c = Cell("single_transmon", nm)
        # Use simulation=true to render simulation-only geometry, `strict=:no` to continue from errors
        render!(c, floorplan, L1_TARGET, strict=:no, simulation=true)
        flatten!(c)
        save(joinpath(@__DIR__, "single_transmon.gds"), c)
    end
    return sm
end

"""
    configfile(sm::SolidModel; palace_build=nothing, solver_order=2, amr=0)

Given a `SolidModel`, assemble a dictionary defining a configuration file for use within
Palace.

  - `sm`: The `SolidModel`from which to construct the configuration file
  - `palace_build = nothing`: Path to a Palace build directory, used to perform validation of
    the configuration file. If not present, no validation is performed.
  - `solver_order = 2`: Finite element order (degree) for the solver. Palace supports arbitrary
    high-order spaces.
  - `amr = 0`: Maximum number of adaptive mesh refinement (AMR) iterations.
"""
function configfile(sm::SolidModel; palace_build=nothing, solver_order=2, amr=0)
    attributes = SolidModels.attributes(sm)

    config = Dict(
        "Problem" => Dict(
            "Type" => "Eigenmode",
            "Verbose" => 2,
            "Output" => joinpath(@__DIR__, "postpro/single-transmon")
        ),
        "Model" => Dict(
            "Mesh" => joinpath(@__DIR__, "single_transmon.msh2"),
            "L0" => 1e-6, # um is Palace default; record it anyway
            "Refinement" => Dict(
                "MaxIts" => amr # Nonzero to enable AMR
            )
        ),
        "Domains" => Dict(
            "Materials" => [
                Dict(
                    # Vaccuum
                    "Attributes" => [attributes["vacuum"]],
                    "Permeability" => 1.0,
                    "Permittivity" => 1.0
                ),
                Dict(
                    # Sapphire
                    "Attributes" => [attributes["substrate"]],
                    "Permeability" => [0.99999975, 0.99999975, 0.99999979],
                    "Permittivity" => [9.3, 9.3, 11.5],
                    "LossTan" => [3.0e-5, 3.0e-5, 8.6e-5],
                    "MaterialAxes" =>
                        [[0.8, 0.6, 0.0], [-0.6, 0.8, 0.0], [0.0, 0.0, 1.0]]
                )
            ],
            "Postprocessing" => Dict(
                "Energy" => [Dict("Index" => 1, "Attributes" => [attributes["substrate"]])]
            )
        ),
        "Boundaries" => Dict(
            "PEC" => Dict("Attributes" => [attributes["metal"]]),
            "Absorbing" => Dict(
                "Attributes" => [attributes["exterior_boundary"]],
                "Order" => 1
            ),
            "LumpedPort" => [
                Dict(
                    "Index" => 1,
                    "Attributes" => [attributes["port_1"]],
                    "R" => 50,
                    "Direction" => "+X"
                ),
                Dict(
                    "Index" => 2,
                    "Attributes" => [attributes["port_2"]],
                    "R" => 50,
                    "Direction" => "+X"
                ),
                Dict(
                    "Index" => 3,
                    "Attributes" => [attributes["lumped_element"]],
                    "L" => 14.860e-9,
                    "C" => 5.5e-15,
                    "Direction" => "+Y"
                )
            ]
        ),
        "Solver" => Dict(
            "Order" => solver_order,
            "Eigenmode" => Dict("N" => 2, "Tol" => 1.0e-6, "Target" => 1, "Save" => 2),
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

"""
    palace_job(config::Dict; palace_build, np=0, nt=1)

Given a configuration dictionary, write and optionally run the Palace simulation.

Writes `config.json` to `@__DIR__` in order to pass the configuration into Palace.

  - `config`: A configuration file defining the required fields for a Palace configuration file
  - `palace_build`: Path to a Palace build.
  - `np = 0`: Number of MPI processes to use in the call to Palace. If greater than 0 attempts
    to call palace from within the Julia shell. Requires correct specification of `ENV[PATH]`.
  - `nt = 1`: Number of OpenMP threads to use in the call to Palace (requires Palace built with
    OpenMP)
"""
function palace_job(config::Dict; palace_build, np=0, nt=1)
    # Write the configuration file to json, ready for Palace ingestion
    println("Writing configuration file to $(joinpath(@__DIR__, "config.json"))")
    open(joinpath(@__DIR__, "config.json"), "w") do f
        return JSON.print(f, config)
    end

    if np > 0
        # Call Palace using the generated configuration file.
        # Record the terminal output and any error to files.
        println("Running Palace: stdout sent to log.out, stderr sent to err.out")
        withenv("PATH" => "$(ENV["PATH"]):$palace_build/bin") do
            return run(
                pipeline(
                    ignorestatus(
                        `palace -np $np -nt $nt $(joinpath(@__DIR__,"config.json"))`
                    ),
                    stdout=joinpath(@__DIR__, "log.out"),
                    stderr=joinpath(@__DIR__, "err.out")
                )
            )
        end
        println("Complete.")

        # Extract the computed frequencies
        postprodir = joinpath(@__DIR__, config["Problem"]["Output"])
        freq = CSV.File(joinpath(postprodir, "eig.csv"); header=1) |> DataFrame

        println("Eigenmode Frequencies (GHz): ", freq[:, 2])
        return freq[:, 2]
    end
    return nothing
end

"""
    compute_eigenfrequencies(palace_build, np=1; solver_order=2, mesh_order=2, cap_length=620μm, total_length=5000μm))

Given a build of Palace found at `palace_build`, assemble a `SolidModel` of the single
transmon example, mesh the geometry, define a configuration file for the geometry, and if
`np > 0`, launch Palace from the provided `palace_build`. (If `0`, use `palace_build`
only to validate config.)

# Keyword arguments

  - `solver_order = 2`: Finite element order (degree) for the solver. Palace supports arbitrary
    high-order spaces.
  - `mesh_order = 2`: Polynomial order used to represent the element geometries in the mesh.
  - `cap_length = 620μm`: Length of transmon island capacitor.
  - `total_length = 5000μm`: Total length of readout resonator.
"""
function compute_eigenfrequencies(
    palace_build,
    np=1;
    solver_order=2,
    mesh_order=2,
    cap_length=620μm,
    total_length=5000μm
)
    # Construct the SolidModel
    @time "SolidModel + Meshing" sm = single_transmon(
        save_mesh=true;
        cap_length=cap_length,
        total_length=total_length,
        mesh_order=mesh_order
    )
    # Assemble the configuration
    @time "Configuration" config = configfile(sm; palace_build, solver_order=solver_order)
    # Call Palace
    @time "Palace" freqs = palace_job(config; palace_build, np)
    return freqs
end

"""
    frequency_targeting_errfunc(targets_GHz, palace_build, np, solver_order, mesh_order, freq_log, param_log)

Create an error function that can be minimized by an optimization routine to reach target frequencies.

The returned function takes parameters that control the transmon's capacitor length and resonator's total length.
It runs `compute_eigenfrequencies` and returns the mean squared relative error between the computed
eigenfrequencies and `targets_GHz`.
It also pushes frequencies and parameter values to the provided arrays `freq_log` and `param_log`.
"""
function frequency_targeting_errfunc(
    targets_GHz,
    palace_build,
    np,
    solver_order,
    mesh_order,
    freq_log,
    param_log
)
    return function errfunc(x, p=()) # Many optimizer interfaces require a second argument for fixed parameters
        freqs = compute_eigenfrequencies(
            palace_build,
            np;
            cap_length=(1 / x[1]^2) * 620μm, # Transform so that frequency(x) is approximately linear
            total_length=(1 / x[2]) * 5000μm, # ... and x_i are all ~1
            solver_order,
            mesh_order
        )[1:2] # [1:2] because technically Palace can find more than two eigenfrequencies
        push!(freq_log, freqs) # Log for later convenience
        push!(param_log, copy(x)) # Copy because `x` gets reused
        return sum((freqs .- targets_GHz) .^ 2 ./ targets_GHz .^ 2) / 2 # Mean squared relative error
    end
end

"""
    run_optimization(palace_build, np=1; targets_GHz=[3.0, 4.0], reltol=1e-2, solver_order=2, mesh_order=2)

Optimize the transmon and resonator parameters to achieve target frequencies.

The objective function generates a new schematic, SolidModel, and mesh;
generates and validates a new Palace configuration file; runs Palace using the mesh
and configuration file; and returns the mean squared relative error between the
computed eigenfrequencies and `targets_GHz`.
The optimization routine stops when the mean squared relative error is less than `reltol^2`.

`np`, `solver_order`, and `mesh_order` are used for configuring and running Palace as in
`compute_eigenfrequencies`.
"""
function run_optimization(
    palace_build,
    np=1;
    targets_GHz=[3.0, 4.0],
    reltol=1e-2,
    solver_order=2,
    mesh_order=2
)
    freq_log = []
    param_log = []
    errfunc = frequency_targeting_errfunc( # Create the objective function for optimization
        targets_GHz,
        palace_build,
        np,
        solver_order,
        mesh_order,
        freq_log,
        param_log
    )
    final_params, info = prima( # Run the optimization
        errfunc,
        [1.0, 1.0]; # Initial parameters
        ftarget=reltol^2, # Stop when `errfunc(x) < reltol^2`
        xl=[0.6, 0.6], # Lower bounds
        xu=[1.4, 1.4], # Upper bounds
        rhobeg=0.2 # Initial trust region radius
    )
    println("""
        Number of Palace runs: $(info.nf)
        Initial parameters:
            Transmon capacitor_length = 620.0μm
            Resonator total_length = 5000.0μm
        Initial frequencies: $(round.(first(freq_log), digits=3)) GHz
        Final parameters:
            Transmon capacitor_length = $(round(μm, 620.0μm/final_params[1]^2, digits=3))
            Resonator total_length = $(round(μm, 5000.0μm/final_params[2], digits=3))
        Final frequencies: $(round.(last(freq_log), digits=3)) GHz
        """)
    return final_params, info, freq_log, param_log
end

end # module
