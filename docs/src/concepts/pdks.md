# [Process Design Kit](@id pdk-architecture)

A [process design kit (PDK)](https://en.wikipedia.org/wiki/Process_design_kit) defines process-specific tools used to assemble designs for fabrication. For example, a typical PDK defines a set of layer names along with the GDS layer and datatype for each of those names. It also defines a set of components using those layers.

In DeviceLayout.jl terms, a PDK would define a layer record mapping names to GDS metadata, as well as a [`ProcessTechnology`](@ref) and [`Target`](@ref SchematicDrivenLayout.Target) for each desired method of creating artwork and simulation files from schematics:

```julia
module MyPDK
using DeviceLayout, DeviceLayout.SchematicDrivenLayout, DeviceLayout.PreferredUnits

const my_layer_record = (;
    metal=GDSMeta(0, 0),
    dielectric=GDSMeta(1, 0),
    chip_area=GDSMeta(100, 0),
    simulated_area=GDSMeta(200, 0)
    # ...
)

const my_process_params = (; # From ExamplePDK: Unrealistic thicknesses for clearer visualizations
    chip_thicknesses=[100μm, 100μm], # [Bottom chip, top chip] (for calculating z height by level)
    flipchip_gaps=[80μm], # Space between chip surfaces (for calculating z height by level)
    height=(; simulated_area=-1mm), # z height at the bottom of simulation volume
    thickness=(; # Extrusion distances for various layers
        simulated_area=2mm,
        dielectric=[2μm, 5μm], # For levelwise layers, specify thickness for each level
        chip_area=[100μm, 100μm]
        # ...
    )
    # ...
)

const MyFlipchipProcess = ProcessTechnology(my_layer_record, my_process_params)

const BottomChipTarget = ArtworkTarget(MyFlipchipProcess, levels=[1])
const TopChipTarget = ArtworkTarget(MyFlipchipProcess, levels=[2])
const SimulationTarget = SolidModelTarget(
    MyFlipchipProcess;
    bounding_layers=[:simulated_area],
    substrate_layers=[:chip_area],
    levelwise_layers=[:chip_area],
    simulation=true
)
end
```

A DeviceLayout.jl PDK would also define any [`Component`s](@ref SchematicDrivenLayout.AbstractComponent) to be used in building schematics. We provide [ExamplePDK](../examples/examplepdk.md) as a module within DeviceLayout.jl as an example.

We recommend organizing your own PDK for use with DeviceLayout.jl is as a single version-controlled repository, with a `MyPDK.jl` package at the top level, defining a module like the above snippet, and component packages in a subdirectory. For example:

```
MyPDK/
├─ Project.toml
├─ README.md
├─ ...
├─ components/
│  ├─ MyInterdigitalCapacitors/
│  │  ├─ Project.toml
│  │  ├─ README.md
│  │  ├─ docs/
│  │  ├─ examples/
│  │  │  └─ example.jl
│  │  ├─ src/
│  │  │  └─ MyInterdigitalCapacitors.jl
│  │  └─ test/
│  ├─ MyMeanderInductors/
│  ├─ MySpiralInductors/
│  └─ ...
├─ docs/
├─ src/
│  └─ MyPDK.jl
└─ test/
```

MyPDK.jl has DeviceLayout.jl as a dependency, and each component package depend on MyPDK.jl (and possibly other components) for layer names and other information or functionality held in common. The PDK and component packages are independently versioned using [semantic versioning](https://semver.org/).

Here, component packages have their own `Project.toml` file distinct from MyPDKPackage because they are separate packages despite living in the same repository. Like
with all Julia packages it is not advised to actually commit `Manifest.toml` files, although it is useful to commit them to one-off "projects" like analyses and layout scripts to enable fully reproducible environments.

This structure can be combined with [LocalRegistry](https://github.com/GunnarFarneback/LocalRegistry.jl/) to make the PDK and component packages available from a private registry. Doing so allows you to use the full power of the [Julia package manager](https://pkgdocs.julialang.org/) by versioning physical designs using semantic versioning, seamlessly tracking and switching between versions as needed.

## See Also

- [Tutorial: Creating a PDK](../tutorials/creating_a_pdk.md) for a walkthrough of PDK creation
- [ExamplePDK](../examples/examplepdk.md), the PDK used for [single transmon](../examples/singletransmon.md) and [QPU](../examples/qpu17.md) examples
- [API Reference: PDKs](@ref api-pdks) for utilities for generating packages and files for PDKs and components from templates
- [API Reference: Technologies](@ref api-technologies) and [Targets](@ref api-targets)