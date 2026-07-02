# QPU17 SolidModel
#
# To run this script:
#
#   Open a Julia REPL in this directory, then:
#     ] activate .
#     ] instantiate            # precompiles dependencies (slow the first time)
#     include("solidmodel.jl") # defines the functions below and builds the schematic/target
#
#   Then drive the simulation interactively:
#     sm   = qpu17_solidmodel(schematic, target)       # render geometry (~30 min)
#     conn = verify_port_connectivity(sm, schematic)   # check + assert port shorts/opens
#     DeviceLayout.save(joinpath(@__DIR__, "qpu17.xao"), sm)  # optional: save geometry
#
#   Mesh, then build a Palace config (pick one simulation type) and optionally run it:
#     meshes = mesh_family(sm; scales=[1.0], order=1)                   # order=2 for driven
#     config = eigenmode_configfile(sm, schematic; mesh_file=meshes[1]) # eigenmode, or:
#     # config = driven_configfile(sm; mesh_file=meshes[1])             # driven sweep
#     palace_job(config; palace_build=..., np=..., nt=...)

using DeviceLayout,
    .SchematicDrivenLayout,
    .PreferredUnits,
    .SchematicDrivenLayout.ExamplePDK
using .ExamplePDK.LayerVocabulary
using FileIO, JSON

include("DemoQPU17.jl")

schematic, artwork = DemoQPU17.qpu17_demo(savegds=true)

place!(schematic.coordinate_system, bounds(schematic.coordinate_system), SIMULATED_AREA)

target = ExamplePDK.SINGLECHIP_SOLIDMODEL_TARGET
if length(target.rendering_options.retained_physical_groups) < 10
    ports = [("port_$i", 2) for i = 1:42]
    lumped_elements = [("lumped_element_$i", 2) for i = 1:34]
    append!(target.rendering_options.retained_physical_groups, ports, lumped_elements)
end

function qpu17_solidmodel(schematic, target)
    sm = SolidModel("demo"; overwrite=true)
    SolidModels.gmsh.option.set_number("General.Verbosity", 2)
    @time "Rendering to SolidModel" render!(sm, schematic, target) # 10-30 min depending on hardware
    # Use SolidModels.gmsh to reach any command in the gmsh Julia API; `mesh_family`
    # generates and saves meshes once the geometry has been rendered.
    return sm
end

"""
    verify_port_connectivity(sm::SolidModel, schematic; n_ports=42) -> Dict

Check 2D connectivity of each `port_i` to `metal` and assert it matches the port's role:
flux (`Z`) ports must be `:short`; charge (`XY`) and readout (`RO`) ports must be `:open`.
Returns the connectivity dict from `SolidModels.check_port_connectivity`.
"""
function verify_port_connectivity(sm::SolidModel, schematic; n_ports=42)
    # Fast without staple detection, but then air bridges don't connect
    # ~1 minute with staples (non-boundary contacts)
    @time conn = SolidModels.check_port_connectivity(
        sm,
        ["port_$i" for i = 1:n_ports],
        ["metal"];
        dim=2,
        detect_non_boundary_contacts=true
    )
    for i = 1:n_ports
        port = "port_$i"
        component_node = schematic.index_dict[:port][i]
        role = split(component_node.component.name, "_")[2]
        if role == "XY" || role == "RO"
            @assert conn[port] == :open "$role port $i is $(conn[port]); should be :open"
        elseif role == "Z"
            @assert conn[port] == :short "$role port $i is $(conn[port]); should be :short"
        else
            error("Invalid port role")
        end
    end
    println("All flux ports are `:short`, and all charge and readout ports are `:open`")
    return conn
end

"""
    driven_configfile(sm::SolidModel, schematic; kwargs...) -> Dict

Assemble a Palace configuration dictionary for a **driven** simulation of the QPU17 model.
The result is directly `JSON.print`-able into a `config.json` that Palace accepts.

Modelled on `SingleTransmon.configfile`, adapted for the QPU17 physical-group layout:

  - 42 `port_i` 2D groups (50 Ω lumped ports; exactly one is the driven excitation)
  - 34 `lumped_element_j` 2D groups (LC lumped elements representing junctions)
  - `vacuum`/`substrate` 3D materials, `metal` PEC, `exterior_boundary` first-order absorbing

# Keyword arguments

  - `palace_build = nothing`: path to a Palace build. When supplied, the function imports
    `JSONSchema` and validates the config against `\$palace_build/bin/schema/config-schema.json`.
    (`JSONSchema` is not a hard dep of this example — add it to the Project if you want validation.)
  - `solver_order = 2`: FE order.
  - `amr = 0`: adaptive mesh refinement iterations.
  - `excitation_port = 1`: which `port_i` gets `Excitation = true`. Every other port is a 50 Ω
    passive termination.
  - `min_freq_ghz`, `max_freq_ghz`, `freq_step_ghz`: driven-sweep bounds (GHz).
  - `save_step = 10`: Paraview output cadence.
  - `n_ports = 42`, `n_lumped_elements = 34`: must match the counts in `retained_physical_groups`.
  - `lumped_L`, `lumped_C`: per-junction inductance/capacitance. The defaults mirror the
    SingleTransmon values, split into two junctions for a SQUID —
    override per-junction by editing the returned dict if needed.
  - `port_R = 50`: termination impedance for 50 Ω ports.
  - `lumped_direction = "+Y"`: lumped element orientation. (Lumped port directions are computed from the schematic.)
  - `mesh_file`: path to the `.msh2` written by `mesh_family`.
"""
function driven_configfile(
    sm::SolidModel,
    schematic;
    palace_build=nothing,
    solver_order=2,
    amr=0,
    excitation_port=1,
    min_freq_ghz=4.0,
    max_freq_ghz=8.0,
    freq_step_ghz=0.05,
    save_step=10,
    n_ports=42,
    n_lumped_elements=34,
    lumped_L=14.860e-9 * 2,
    lumped_C=5.5e-15 / 2,
    port_R=50,
    lumped_direction="+Y",
    mesh_file=joinpath(@__DIR__, "qpu17.msh2")
)
    attributes = SolidModels.attributes(sm)
    config = base_config(sm, schematic;
        mesh_file, amr, n_ports, n_lumped_elements,
        lumped_L, lumped_C, port_R, lumped_direction)

    # Build LumpedPort entries: driven 50Ω ports first (one excited), then LC junctions.
    lumped_ports = config["Boundaries"]["LumpedPort"]
    for i = 1:n_ports
        lumped_ports[i]["Excitation"] = i == excitation_port
    end
    config["Problem"]["Type"] = "Driven"
    config["Solver"] = Dict(
        "Order" => solver_order,
        "Driven" => Dict(
            "MinFreq" => min_freq_ghz,
            "MaxFreq" => max_freq_ghz,
            "FreqStep" => freq_step_ghz,
            "SaveStep" => save_step
        ),
        "Linear" => 
            Dict("Type" => "Default", "Tol" => 1.0e-7, "MaxIts" => 500)
    )

    if !isnothing(palace_build)
        validate_schema(config, palace_build)
    end

    return config
end

"""
    eigenmode_configfile(sm::SolidModel, schematic; kwargs...) -> Dict

Assemble a Palace **eigenmode** configuration for the QPU17 model. Port and lumped-element
directions are read from each component's placement in `schematic` (unlike [`configfile`](@ref),
which uses a single fixed direction for the driven sweep), and `exterior_boundary` is treated
as PEC here rather than absorbing.

# Keyword arguments

  - `palace_build = nothing`: path to a Palace build. When supplied, the function imports
    `JSONSchema` and validates the config against `\$palace_build/bin/schema/config-schema.json`.
    (`JSONSchema` is not a hard dep of this example — add it to the Project if you want validation.)
  - `mesh_file`: path to the `.msh2` to simulate (e.g. an entry returned by `mesh_family`).
  - `solver_order = 2`: FE order.
  - `n_modes = 2`: number of eigenmodes to solve for.
  - `amr = 0`: adaptive mesh refinement iterations.
  - `n_ports = 42`, `n_lumped_elements = 34`: must match the counts in `retained_physical_groups`.
  - `lumped_L`, `lumped_C`: per-junction inductance/capacitance. The defaults mirror the
    SingleTransmon values, split into two junctions for a SQUID —
    override per-junction by editing the returned dict if needed.
  - `port_R = 50`: termination impedance for 50 Ω ports.
  - `lumped_direction = "+Y"`: lumped element orientation. (Lumped port directions are computed from the schematic.)
"""
function eigenmode_configfile(
    sm::SolidModel,
    schematic;
    palace_build=nothing,
    mesh_file=joinpath(@__DIR__, "qpu17.msh2"),
    solver_order=2,
    n_modes=2,
    amr=0,
    n_ports=42,
    n_lumped_elements=34,
    lumped_L=14.860e-9 * 2,
    lumped_C=5.5e-15 / 2,
    port_R=50,
    lumped_direction="+Y",
)
    config = base_config(sm, schematic;
        mesh_file, amr, n_ports, n_lumped_elements,
        lumped_L, lumped_C, port_R, lumped_direction)
    config["Problem"]["Type"] = "Eigenmode"

    config["Solver"] = Dict(
        "Order" => solver_order,
        "Eigenmode" =>
            Dict("N" => n_modes, "Tol" => 1.0e-6, "Target" => 2, "Save" => n_modes),
        "Linear" => 
            Dict("Type" => "Default", "Tol" => 1.0e-7, "MaxIts" => 500)
    )

    if !isnothing(palace_build)
        validate_schema(config, palace_build)
    end

    return config
end

function base_config(sm, schematic;
    mesh_file=joinpath(@__DIR__, "qpu17.msh2"),
    amr=0,
    n_ports=42,
    n_lumped_elements=34,
    lumped_L=14.860e-9 * 2,
    lumped_C=5.5e-15 / 2,
    port_R=50,
    lumped_direction="+Y",
)
    attributes = SolidModels.attributes(sm)
    lumped_ports = Dict[]
    for i = 1:n_ports
        node = schematic.index_dict[:port][i]
        dirs = Dict(0.0° => "+X", 90.0° => "+Y",
            180.0° => "-X", 270.0° => "-Y")
        dir = dirs[rem(
            rotation(transformation(schematic, node)), 360°, RoundDown)]
        push!(
            lumped_ports,
            Dict(
                "Index" => i,
                "Attributes" => [attributes["port_$i"]],
                "R" => port_R,
                "Direction" => dir
            )
        )
    end
    for j = 1:n_lumped_elements
        push!(
            lumped_ports,
            Dict(
                "Index" => n_ports + j,
                "Attributes" => [attributes["lumped_element_$j"]],
                "L" => lumped_L + j*0.05e-9, # Stagger to avoid degeneracy
                "C" => lumped_C,
                "Direction" => lumped_direction
            )
        )
    end
    config = Dict(
        "Problem" => Dict(
            "Type" => "Driven",
            "Verbose" => 2,
            "Output" => joinpath(@__DIR__, "postpro/qpu17")
        ),
        "Model" => Dict(
            "Mesh" => mesh_file,
            "L0" => 1e-6, # µm is Palace's default length unit; record it anyway
            "Refinement" => Dict("MaxIts" => amr)
        ),
        "Domains" => Dict(
            "Materials" => [
                Dict(
                    # Vacuum
                    "Attributes" => [attributes["vacuum"]],
                    "Permeability" => 1.0,
                    "Permittivity" => 1.0
                ),
                Dict(
                    # Sapphire (values match SingleTransmon example)
                    "Attributes" => [attributes["substrate"]],
                    "Permeability" => [0.99999975, 0.99999975, 0.99999979],
                    "Permittivity" => [9.3, 9.3, 11.5],
                    "LossTan" => [3.0e-5, 3.0e-5, 8.6e-5],
                    "MaterialAxes" =>
                        [[0.8, 0.6, 0.0], [-0.6, 0.8, 0.0], [0.0, 0.0, 1.0]]
                )
            ],
            "Postprocessing" => Dict(
                "Energy" => [Dict("Index" => 1,"Attributes" => [attributes["substrate"]])]
            )
        ),
        "Boundaries" => Dict(
            "PEC" => Dict("Attributes" => [attributes["metal"]]),
            "Absorbing" =>
                Dict("Attributes" => [attributes["exterior_boundary"]],
                     "Order" => 1),
            "LumpedPort" => lumped_ports
        ),
    )
    return config
end

function validate_schema(config, palace_build)
    # Lazy-load JSONSchema so the example stays usable without it as a hard dep.
    @eval Main import JSONSchema
    schema_dir = joinpath(palace_build, "bin", "schema")
    schema = Main.JSONSchema.Schema(
        JSON.parsefile(joinpath(schema_dir, "config-schema.json"));
        parent_dir=schema_dir
    )
    Main.JSONSchema.validate(schema, config)
end

"""
    palace_job(config::Dict; palace_build=nothing, np=0, nt=1) -> Nothing

Write `config` to `config.json` next to this script, and optionally invoke Palace.
Mirrors `SingleTransmon.palace_job` but without the post-run eigenmode-CSV parsing
(driven sweeps produce `port-S.csv` etc. — inspect those yourself in `postpro/qpu17`).
"""
function palace_job(config::Dict; palace_build=nothing, np=0, nt=1)
    cfg_path = joinpath(@__DIR__, "config.json")
    println("Writing configuration file to $cfg_path")
    open(cfg_path, "w") do f
        return JSON.print(f, config, 2)
    end

    if np > 0 && !isnothing(palace_build)
        println("Running Palace: stdout -> log.out, stderr -> err.out")
        withenv("PATH" => "$(ENV["PATH"]):$palace_build/bin") do
            return run(
                pipeline(
                    ignorestatus(`palace -np $np -nt $nt $cfg_path`),
                    stdout=joinpath(@__DIR__, "log.out"),
                    stderr=joinpath(@__DIR__, "err.out")
                )
            )
        end
    end
    return nothing
end

"""
    mesh_family(sm::SolidModel; scales=[1.0, 0.5, 0.25], basename="qpu17", order=2)
        -> Vector{String}

Generate a sequence of meshes on the already-rendered `sm`, one per entry of `scales`, by
setting `SolidModels.mesh_scale(s)`, clearing any existing mesh, and regenerating 1D/2D/3D
at the requested element `order`. Each mesh is saved to `\$basename.h\$i.msh2` next to this
script, where `i` is the index into `scales` (0-based).

Returns the vector of absolute filenames, in the same order as `scales`, suitable for
passing to `configfile(sm; mesh_file=...)` or `eigenmode_configfile(sm, schematic; mesh_file=...)`.

The size-field callback reads `mesh_scale()` at evaluation time (see
`src/solidmodels/render.jl`), so changing the scale between runs does not require
re-rendering the geometry — only clearing + regenerating the mesh.
"""
function mesh_family(
    sm::SolidModel;
    scales=[1.0, 0.5, 0.25],
    basename="qpu17",
    order=2
)
    # Quadratic elements, with high-order optimization enabled (default).
    SolidModels.mesh_order(order)
    SolidModels.mesh_grading_default(0.75)

    files = String[]
    for (i, s) in enumerate(scales)
        label = "h$(i - 1), scale=$s"
        SolidModels.mesh_scale(s)
        SolidModels.gmsh.model.mesh.clear()
        @time "Generating 1D Mesh ($label)" SolidModels.gmsh.model.mesh.generate(1)
        @time "Generating 2D Mesh ($label)" SolidModels.gmsh.model.mesh.generate(2)
        @time "Generating 3D Mesh ($label)" SolidModels.gmsh.model.mesh.generate(3)

        path = joinpath(@__DIR__, "$(basename).h$(i - 1).msh2")
        @time "Saving $path" save(path, sm)
        push!(files, path)
    end
    return files
end
