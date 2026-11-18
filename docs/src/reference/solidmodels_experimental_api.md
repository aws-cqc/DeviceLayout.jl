# [Experimental Solid Model API Reference](@id solidmodels-experimental-api)

See [Solid Models (Experimental)](../concepts/solidmodels_experimental.md)
for how these fit together. The module exports nothing; import names from
`DeviceLayout.SolidModelsExperimental`.

## Layers and source stacks

```@docs
DeviceLayout.SolidModelsExperimental.LayerRef
DeviceLayout.SolidModelsExperimental.Material
DeviceLayout.SolidModelsExperimental.SourceLayer
DeviceLayout.SolidModelsExperimental.SourceStack
```

## Locators

```@docs
DeviceLayout.SolidModelsExperimental.Locator
DeviceLayout.SolidModelsExperimental.LocatorMeta
DeviceLayout.SolidModelsExperimental.Terminal
DeviceLayout.SolidModelsExperimental.Ground
DeviceLayout.SolidModelsExperimental.Tag
DeviceLayout.SolidModelsExperimental.Port
DeviceLayout.SolidModelsExperimental.WavePort
DeviceLayout.SolidModelsExperimental.LumpedPort
```

## Operations

```@docs
DeviceLayout.SolidModelsExperimental.Extrude
DeviceLayout.SolidModelsExperimental.Hollow
DeviceLayout.SolidModelsExperimental.Cut
DeviceLayout.SolidModelsExperimental.Fuse
DeviceLayout.SolidModelsExperimental.Intersect
DeviceLayout.SolidModelsExperimental.GetInterface
DeviceLayout.SolidModelsExperimental.RestrictTo
DeviceLayout.SolidModelsExperimental.GetBoundary
DeviceLayout.SolidModelsExperimental.exterior_boundaries
DeviceLayout.SolidModelsExperimental.Translate
DeviceLayout.SolidModelsExperimental.Remove
DeviceLayout.SolidModelsExperimental.Revolve
DeviceLayout.SolidModelsExperimental.SetPeriodic
```

## Rendering

```@docs
DeviceLayout.SolidModelsExperimental.SolidModelTarget
render!(::DeviceLayout.SolidModel, ::DeviceLayout.SchematicDrivenLayout.Schematic, ::DeviceLayout.SolidModelsExperimental.SolidModelTarget)
render!(::DeviceLayout.Cell, ::Any, ::DeviceLayout.SolidModelsExperimental.SourceStack)
```
