# Single transmon with readout resonator

In this example, we demonstrate the layout and solid model generation of a single transmon
coupled to a readout resonator. In particular, this example demonstrates the additional steps
necessary to generate a mesh suitable for electromagnetic simulation using external
applications, such as the [*Palace*](https://github.com/awslabs/palace) solver. *Palace* is
an open-source, parallel finite element code for full-wave 3D electromagnetic simulations. This example
constructs the geometry used in [the *Palace* release documentation](https://aws.amazon.com/blogs/quantum-computing/aws-releases-open-source-software-palace-for-cloud-based-electromagnetics-simulations-of-quantum-computing-hardware/) and is aimed at
demonstrating the power of the [`SolidModels`](../schematicdriven/solidmodels.md)
capability for electronic design automation in an open-source toolchain.

The full code for this example can be found [in `examples/SingleTransmon/SingleTransmon.jl` in the `DeviceLayout.jl` repository](https://github.com/aws-cqc/DeviceLayout.jl/blob/main/examples/SingleTransmon/SingleTransmon.jl). Components and process technology are drawn from the
[ExamplePDK](examplepdk.md).

## Overview

The single transmon schematic is simple, consisting of three components: an
[`ExampleRectangleTransmon`](./examplepdk.md#Transmons), an
[`ExampleClawedMeanderReadout`](./examplepdk.md#ReadoutResonators), and a coplanar-waveguide readout line.
The readout line additionally demonstrates how to terminate a path using lumped ports. The `single_transmon`
function generates the schematic, renders it to a `SolidModel`, and generates a mesh.

Once the mesh has been generated, the `configfile` function will
ingest the `SolidModel` and return a dictionary representing a *Palace* configuration. If
a *Palace* build directory is provided, then the configuration file will be
validated using the *Palace* provided JSON schema.

The generated configuration and mesh files can then be run directly from within `julia`
using `palace_job(config::Dict; palace_build, np=0, nt=1)` which will write the `config`
to `config.json` and if `np > 0` attempt to run the *Palace* job from within the `julia`
shell mode. If `np = 0` the configuration file will still be written to disk ready for a manual
call to *Palace* outside of `julia`.

These three functions are all wrapped together in `compute_eigenfrequencies` which will
build the `SolidModel` and write the mesh and configuration file to disk, before optionally
attempting to run *Palace*:

```julia
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
```

Each of these three steps is discussed in more detail below.

In the final section, we use this pipeline inside an optimization routine
to tune up the transmon and resonator frequencies to desired targets.

## SolidModel construction and meshing

To run the example we `include` the `example/SingleTransmon/SingleTransmon.jl` file and
then call `single_transmon()`. This will construct the schematic and render the design to
`SolidModel`. To visualize the resulting model in `Gmsh`, we then call
`SolidModels.gmsh.fltk.run()`.

```julia
using DeviceLayout
include("examples/SingleTransmon/SingleTransmon.jl")
sm = SingleTransmon.single_transmon()
SolidModels.gmsh.fltk.run() # Opens Gmsh GUI
```

Below, we show the mesh for the metal surfaces. You can also (barely) see the lumped ports at the ends of the readout line in red.

```@raw html
<img src="../../assets/single_transmon_mesh.png"/>
```

The function exposes a number of parameters for the definition of the transmon and readout
resonator, demonstrating how the kernel for an automated parameter search might be
established. Aside from the design parameters there are two processing arguments:
`save_mesh::Bool`, which performs the meshing of the `SolidModel` and writes the resulting
mesh to disk as `single_transmon.msh2` in the Gmsh 2.2 mesh format, and
`save_gds::Bool`, which generates a GDS of the schematic and writes the resulting design to
`single_transmon.gds`. Finally, there's a `mesh_order` keyword that sets the element
order for the generated mesh.

The schematic design is significantly simplified compared to that of the [quantum processor
example](qpu17.md), but has the same general structure. The three components are
added to the schematic graph and attached to each other before being placed by `plan` into a floorplan,
which is then furnished with air bridges.

The transmon and resonator definitions in ExamplePDK take steps to improve the quality of the initial mesh—for example,
to avoid creating long, skinny triangles. In many cases, defaults are sufficient to resolve
the geometry as a starting point for refinement, but component designers can often use their knowledge
to make improvements. This is accomplished by adding [mesh sizing information](@ref MeshSized)
to particular shapes in a component's `_geometry!` functions.

When we `render!` the floorplan to a `SolidModel`, instead of a `LayoutTarget` we provide a [`SolidModelTarget`](@ref SchematicDrivenLayout.SolidModelTarget) containing information about how to generate the 3D model. The `SolidModelTarget` is based on this definition from `ExamplePDK`:

```julia
"""
    const SINGLECHIP_SOLIDMODEL_TARGET::SolidModelTarget

A `Target` for rendering to a `SolidModel` using the `ExamplePDK`'s process technology.

Contains rendering options and postrendering operations to create a solid model suitable
for simulation of a single-chip device (as opposed to a flipchip device).
"""
const SINGLECHIP_SOLIDMODEL_TARGET = SolidModelTarget(
    EXAMPLE_SINGLECHIP_TECHNOLOGY; # Thickness and height define z-height and extrusions
    simulation=true, # Optional simulation-only geometry entities will be rendered
    bounding_layers=[:simulated_area], # SIMULATED_AREA defines the simulation bounds
    substrate_layers=[:chip_area], # CHIP_AREA will be extruded downward
    indexed_layers=[:port, :lumped_element, :integration], # Automatically index these layers
    postrender_ops=[ # Manual definition of operations to run after 2D rendering
        (   # Get metal ground plane by subtracting negative from writeable area
            "metal", # Output group name
            SolidModels.difference_geom!, # Operation
            ("writeable_area", "metal_negative", 2, 2), # (object, tool, object_dim, tool_dim)
            :remove_object => true # Remove "writeable_area" group after operation
        ),
        (   # Then add any positive back in
            "metal",
            SolidModels.union_geom!,
            ("metal", "metal_positive", 2, 2),
            :remove_tool => true
        ),
        (   # Define a bulk physical group for all the substrates in the domain.
            "substrate",
            SolidModels.union_geom!,
            ("chip_area_extrusion", "chip_area_extrusion", 3, 3),
            :remove_object => true,
            :remove_tool => true
        ),
        (   # Define the vacuum domain as the remainder of the simulation domain.
            "vacuum",
            SolidModels.difference_geom!,
            ("simulated_area_extrusion", "substrate", 3, 3)
        ),
        # Generate staple bridges in "bridge_metal" group
        SolidModels.staple_bridge_postrendering(;
            base="bridge_base",
            bridge="bridge",
            bridge_height=10μm # Exaggerated, for visualization
        )...,
        (   # Union of all physical metal
            "metal",
            SolidModels.union_geom!,
            ("metal", "bridge_metal"),
            :remove_object => true,
            :remove_tool => true
        ),
        (("metal", SolidModels.difference_geom!, ("metal", "port")))
    ],
    # We only want to retain physical groups that we will need for specifying boundary
    # conditions in the physical domain.
    retained_physical_groups=[
        ("vacuum", 3),
        ("substrate", 3),
        ("metal", 2),
        ("exterior_boundary", 2)
    ]
)
```

We modify it slightly to retain `port_1`, `port_2`, and `lumped_element` physical groups in order to use those in the simulation configuration.

## Configuration

Next, we generate a dictionary defining a *Palace* configuration, specifying the problem type, model, materials, boundary conditions, and solver settings. We can also validate the configuration if we have a path to a *Palace* build, which contains the schema for validation. For more details on configuration, see [the *Palace* documentation](https://awslabs.github.io/palace/stable/config/config/).

For this example, we define most of the configuration by hand. However, we need to identify which materials and boundary conditions apply to which volumes and surfaces in the model.

By construction, the `SolidModel` contains physical groups identifying the volumes and surfaces we're interested in. Using `SolidModels.attributes`, we can get a dictionary mapping the names of the physical groups to the integer "attribute" identifying the corresponding entities in the mesh. We can then use this dictionary to populate the configuration automatically according to the physical intent behind the model, without having to worry about whether the underlying geometry or attribute numbering might change.

```julia
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
                    # Vacuum
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
```

The output should look like this:

```jl
Configuration: 0.000082 seconds (327 allocations: 31.391 KiB)
Dict{String, Dict{String, Any}} with 5 entries:
  "Problem"    => Dict("Verbose"=>...)
  "Boundaries" => Dict("LumpedPort"=>...)
  "Model"      => Dict("Refinement"=>...)
  "Domains"    => Dict("Postprocessing"=>...)
  "Solver"     => Dict("Eigenmode"=>...)
```

## *Palace*

Finally, we write the configuration to a file, call *Palace*, and parse the computed eigenfrequencies from its output:

```julia
"""
    palace_job(config::Dict; palace_build, np=0, nt=1)

Given a configuration dictionary, write and optionally run the Palace simulation.

Writes `config.json` to `@__DIR__` in order to pass the configuration into Palace.

  - `config` - A configuration file defining the required fields for a Palace configuration file
  - `palace_build` - Path to a Palace build.
  - `np = 0` - Number of MPI processes to use in the call to Palace. If greater than 0 attempts
    to call palace from within the Julia shell. Requires correct specification of `ENV[PATH]`.
  - `nt = 1` - Number of OpenMp threads to use in the call to Palace (requires Palace built with
    OpenMp)
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
```

For a quick demo to show a working pipeline, we'll run the example with `solver_order=1` and `mesh_order=1`,
sacrificing accuracy for speed. The output should look like this:

```julia
julia> SingleTransmon.compute_eigenfrequencies("/path/to/palace", 1; solver_order=1, mesh_order=1)
[output from generating SolidModel and mesh...]
[output from generating and validating configuration...]
Writing configuration file to /path/to/your/config.json
Running Palace: stdout sent to log.out, stderr sent to err.out
Complete.
Eigenmode Frequencies (GHz): [3.370141242, 5.24366656]
Palace: 63.673291 seconds (671 allocations: 47.422 KiB)
```

You might get different frequencies, because with these order settings, the results are quite
sensitive to the discretization. The *Palace* solver is deterministic (although you may see slight changes
as you change the number of MPI processes), but the meshing algorithm is deterministic only when
single-threaded.
Even in a deterministic setting, because of this sensitivity, changes in parameters
can result in "noisy" changes in the solution since the discretization will change unpredictably.
Moreover, changes between DeviceLayout versions may also affect this example, and the above snippet
is not necessarily updated with each version.

!!! info
    
    The mesh order and solver order are two different but related things. They work together to improve the accuracy
    of your modeling in different ways. In both cases, the order is telling you the degree of the polynomial used
    either to construct the mesh elements or to approximate the solution within each finite element. High-order
    mesh elements are particularly useful for discretizing curved geometries, while increasing the solver order
    can be understood as an alternative to mesh refinement to better model fine variation in solution fields.
    Notably, a second order mesh is ignored if the solver is only first order, but a second order solver is still
    useful if a first order mesh is used.

## Closed-loop optimization

Above, we demonstrated the `compute_eigenfrequencies` function, which runs CAD, meshing, and finite element analysis,
and returns the eigenfrequencies of the transmon and readout resonator. Now we show how such a function can be used
inside an optimization routine.

For this example, we create a function for optimization to minimize, which computes the average squared error
between the computed eigenfrequencies and specified target frequencies:

```julia
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
```

This objective function can be used with any black-box (gradient-free) optimization method. As a demonstration,
we use [PRIMA](https://github.com/libprima/prima), a modern re-implementation of Powell's methods with
[a Julia interface](https://github.com/libprima/prima.jl). These are a family
of trust-region methods that build a quadratic approximation to the objective function.
We take certain steps to improve the convergence of optimization:

  - We use transformed parameters `x` to approximately linearize the frequencies as a function of `x`,
    with each element of `x` having similar magnitude around `1.0`.
  - We use `solver_order=2` and `mesh_order=2` to reduce sensitivity to the discretization, since if we use order 1 as above, the results
    are too noisy for optimization to converge. Note that this does not
    mean that the eigenfrequencies found by *Palace* will have converged to their true values—only that small changes in the model
    will not produce random changes in solutions that are large compared to our desired tolerance.

We run the optimization routine with the following function:

```julia
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
```

We can run this with the default settings to tune the frequencies to within 1% of the targets.
If running *Palace* with a single process, this can take several hours. If we run with
`np = 8` on a single [m6i.4xlarge instance](https://aws.amazon.com/ec2/instance-types/m6i/),
the results look like this:

```julia
julia> @time "Total" SingleTransmon.run_optimization("/path/to/palace", 8)
[output from each iteration...]
Number of Palace runs: 9
Initial parameters:
    Transmon capacitor_length = 620.0μm
    Resonator total_length = 5000.0μm
Initial frequencies: [4.14, 5.591] GHz
Final parameters:
    Transmon capacitor_length = 1217.678 μm
    Resonator total_length = 7243.955 μm
Final frequencies: [3.005, 3.982] GHz

Total: 2425.515197 seconds (2.21 M allocations: 154.640 MiB, 0.01% gc time, 0.00% compilation time)
```

You may get slightly different results for given parameter values, but any differences
should be much smaller than with the `solver_order=1, mesh_order=1` example above. Optimization
should converge in around 10 iterations regardless of these small differences.

As a final note, this example isn't meant to demonstrate a practical method for tuning up a real device.
It's meant to demonstrate a closed loop built on an automated pipeline that includes schematic
specification, 3D model generation, and finite element analysis. Here, the black-box optimization
routine from PRIMA provides the outer logic that handles simulation results and starts the next
iteration, but being able to run the inner pipeline within a Julia session enables many options for
electronic design automation.
