# Schematic-Driven Design API Reference

### [Components](@id api-components)

```@docs
    SchematicDrivenLayout.AbstractComponent
    SchematicDrivenLayout.Component
    SchematicDrivenLayout.@compdef
    SchematicDrivenLayout.@component
    SchematicDrivenLayout.allowed_rotation_angles
    SchematicDrivenLayout.check_rotation
    SchematicDrivenLayout.create_component
    SchematicDrivenLayout.matching_hooks
    SchematicDrivenLayout.matching_hook
    SchematicDrivenLayout.geometry
    SchematicDrivenLayout.hooks
    SchematicDrivenLayout.default_parameters
    halo(::SchematicDrivenLayout.AbstractComponent, ::Any, ::Any)
    SchematicDrivenLayout.name(::SchematicDrivenLayout.AbstractComponent)
    SchematicDrivenLayout.non_default_parameters
    SchematicDrivenLayout.parameters
    SchematicDrivenLayout.parameter_names
    SchematicDrivenLayout.set_parameters
    SchematicDrivenLayout.base_variant
    SchematicDrivenLayout.flipchip!
    SchematicDrivenLayout.@variant
    SchematicDrivenLayout.@composite_variant
```

#### Built-in Components

```@docs
SchematicDrivenLayout.ArrowAnnotation
SchematicDrivenLayout.BasicComponent
SchematicDrivenLayout.GDSComponent
SchematicDrivenLayout.Spacer
SchematicDrivenLayout.WeatherVane
```

#### Composite Components

```@docs
SchematicDrivenLayout.AbstractCompositeComponent
SchematicDrivenLayout.CompositeComponent
SchematicDrivenLayout.BasicCompositeComponent
SchematicDrivenLayout.components(::SchematicDrivenLayout.CompositeComponent)
SchematicDrivenLayout.filter_parameters
SchematicDrivenLayout.flatten(::SchematicDrivenLayout.SchematicGraph)
SchematicDrivenLayout.graph
SchematicDrivenLayout.map_hooks
```

### [Hooks](@id api-hooks)

```@docs
    SchematicDrivenLayout.Hook
    SchematicDrivenLayout.PointHook
    SchematicDrivenLayout.HandedPointHook
    DeviceLayout.hooks(::Path) 
    SchematicDrivenLayout.p0_hook
    SchematicDrivenLayout.p1_hook
    SchematicDrivenLayout.in_direction
    SchematicDrivenLayout.out_direction
    SchematicDrivenLayout.path_in
    SchematicDrivenLayout.path_out
    SchematicDrivenLayout.transformation(::DeviceLayout.PointHook, ::DeviceLayout.PointHook)
    SchematicDrivenLayout.compass
```

### [Autofill](@id api-autofill)

```@docs
    Autofill.autofill!
    Autofill.halo
    Autofill.make_halo
```

### [Schematics](@id api-schematics)

#### Schematic Graph

```@docs
SchematicDrivenLayout.SchematicGraph
SchematicDrivenLayout.ComponentNode
SchematicDrivenLayout.add_node!
SchematicDrivenLayout.fuse!
route!(::SchematicDrivenLayout.SchematicGraph,
    ::Paths.RouteRule,
    ::Pair{SchematicDrivenLayout.ComponentNode, Symbol},
    ::Pair{SchematicDrivenLayout.ComponentNode, Symbol},
    ::Any,
    ::Any)
SchematicDrivenLayout.RouteComponent
attach!(::SchematicDrivenLayout.SchematicGraph,
    ::S,
    ::Pair{T, Symbol},
    ::DeviceLayout.Coordinate
) where {S <: SchematicDrivenLayout.ComponentNode, T <: SchematicDrivenLayout.ComponentNode}
SchematicDrivenLayout.plan
```

#### Schematic

```@docs
SchematicDrivenLayout.Schematic
SchematicDrivenLayout.bounds(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.center(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.crossovers!
SchematicDrivenLayout.find_components
SchematicDrivenLayout.find_nodes
SchematicDrivenLayout.hooks(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.indexof(::SchematicDrivenLayout.ComponentNode, ::SchematicDrivenLayout.SchematicGraph)
SchematicDrivenLayout.origin(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.position_dependent_replace!
SchematicDrivenLayout.replace_component!
SchematicDrivenLayout.rotations_valid
SchematicDrivenLayout.transformation(::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.ComponentNode)
SchematicDrivenLayout.check!
SchematicDrivenLayout.build!
SchematicDrivenLayout.render!(::SchematicDrivenLayout.AbstractCoordinateSystem, ::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.LayoutTarget; kwargs...)
render!(::DeviceLayout.SolidModel, ::SchematicDrivenLayout.Schematic, ::SchematicDrivenLayout.Target; kwargs...)
```

### [Technologies](@id api-technologies)

```@docs
SchematicDrivenLayout.ProcessTechnology
SchematicDrivenLayout.chip_thicknesses
SchematicDrivenLayout.flipchip_gaps
SchematicDrivenLayout.layer_thickness
SchematicDrivenLayout.layer_height
SchematicDrivenLayout.layer_z
SchematicDrivenLayout.level_z
```

### [Targets](@id api-targets)

```@docs
    SchematicDrivenLayout.Target
    SchematicDrivenLayout.LayoutTarget
    SchematicDrivenLayout.ArtworkTarget
    SchematicDrivenLayout.SimulationTarget
    SchematicDrivenLayout.SolidModelTarget
    SchematicDrivenLayout.backing
    SchematicDrivenLayout.facing
    SchematicDrivenLayout.not_simulated
    SchematicDrivenLayout.only_simulated
    SchematicDrivenLayout.not_solidmodel
    SchematicDrivenLayout.only_solidmodel
```

### [PDKs](@id api-pdks)

```@docs
SchematicDrivenLayout.generate_component_definition
SchematicDrivenLayout.generate_component_package
SchematicDrivenLayout.generate_pdk
```
