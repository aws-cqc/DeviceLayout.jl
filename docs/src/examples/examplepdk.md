# ExamplePDK

`ExamplePDK` is [a DeviceLayout.jl PDK](../concepts/pdks.md) containing layer definitions, components, and rendering targets for an example process technology.

!!! warning
    
    `ExamplePDK` is intended for demonstrations, tutorials, and tests. While we aim to demonstrate best practices for Julia code and DeviceLayout.jl usage, these components are not optimized for device performance. Most importantly: **Breaking changes to `ExamplePDK` may occur within major versions.** In other words, don't depend on `ExamplePDK` in your own PDK or for real devices!

!!! info
    
    `ExamplePDK` is written to model best practices for developing your own PDK, with a small caveat about how the PDK is packaged.
    For the sake of convenient testing and tutorials, `ExamplePDK` is just a `SchematicDrivenLayout`
    submodule, and component modules are defined as submodules within `ExamplePDK` by including
    their source files.
    However, when you create your own PDK, we recommend making separate packages for each independent component,
    each of which has your PDK package as a dependency and uses its layer vocabulary.
    That way, you can add, edit, and version technologies and components independently.
    The files can be organized in a similar way within a single repository, but as separate packages
    registered to your private Julia package registry.
    Each subfolder in `MyPDK/components/` would represent its own package (e.g., MyClawCapacitors.jl)
    with its own `Project.toml` specifying a version number, dependencies, and compatibility
    requirements. See the [documentation on PDKs](../concepts/pdks.md) for more detail.

```@docs
SchematicDrivenLayout.ExamplePDK.LAYER_RECORD
SchematicDrivenLayout.ExamplePDK.LayerVocabulary
SchematicDrivenLayout.ExamplePDK.EXAMPLE_SINGLECHIP_TECHNOLOGY
SchematicDrivenLayout.ExamplePDK.EXAMPLE_FLIPCHIP_TECHNOLOGY
SchematicDrivenLayout.ExamplePDK.SINGLECHIP_SOLIDMODEL_TARGET
SchematicDrivenLayout.ExamplePDK.singlechip_solidmodel_target
SchematicDrivenLayout.ExamplePDK.FLIPCHIP_SOLIDMODEL_TARGET
SchematicDrivenLayout.ExamplePDK.flipchip_solidmodel_target
```

## ChipTemplates

```@docs
SchematicDrivenLayout.ExamplePDK.ChipTemplates
SchematicDrivenLayout.ExamplePDK.ChipTemplates.ExampleChip
SchematicDrivenLayout.ExamplePDK.ChipTemplates.example_launcher
```

## ClawCapacitors

```@docs
SchematicDrivenLayout.ExamplePDK.ClawCapacitors
SchematicDrivenLayout.ExamplePDK.ClawCapacitors.ExampleSeriesClawCapacitor
SchematicDrivenLayout.ExamplePDK.ClawCapacitors.ExampleShuntClawCapacitor
```

## ReadoutResonators

```@docs
SchematicDrivenLayout.ExamplePDK.ReadoutResonators
SchematicDrivenLayout.ExamplePDK.ReadoutResonators.ExampleClawedMeanderReadout
SchematicDrivenLayout.ExamplePDK.ReadoutResonators.ExampleTappedHairpin
SchematicDrivenLayout.ExamplePDK.ReadoutResonators.ExampleFilteredHairpinReadout
```

## SimpleJunctions

```@docs
SchematicDrivenLayout.ExamplePDK.SimpleJunctions
SchematicDrivenLayout.ExamplePDK.SimpleJunctions.ExampleSimpleJunction
SchematicDrivenLayout.ExamplePDK.SimpleJunctions.ExampleSimpleSQUID
```

## Transmons

```@docs
SchematicDrivenLayout.ExamplePDK.Transmons
SchematicDrivenLayout.ExamplePDK.Transmons.ExampleRectangleTransmon
SchematicDrivenLayout.ExamplePDK.Transmons.ExampleRectangleIsland
SchematicDrivenLayout.ExamplePDK.Transmons.ExampleStarTransmon
SchematicDrivenLayout.ExamplePDK.Transmons.ExampleStarIsland
SchematicDrivenLayout.ExamplePDK.Transmons.ExampleXYTermination
SchematicDrivenLayout.ExamplePDK.Transmons.ExampleZTermination
```
