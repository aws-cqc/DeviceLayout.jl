# ParameterSet API Reference

For usage and examples, see the [Data-Driven Design with ParameterSet](../tutorials/parameter_set.md) tutorial.

```@docs
DeviceLayout.SchematicDrivenLayout.ParameterSet
DeviceLayout.SchematicDrivenLayout.MissingNamespace
DeviceLayout.SchematicDrivenLayout.ParameterKeyError
DeviceLayout.SchematicDrivenLayout.resolve
DeviceLayout.SchematicDrivenLayout.leaf_params
DeviceLayout.SchematicDrivenLayout.save_parameter_set
```

## Component construction from a `ParameterSet`

```@docs
SchematicDrivenLayout.create_component(::Type{T}, ::DeviceLayout.SchematicDrivenLayout.ParameterSet, ::String) where {T <: DeviceLayout.SchematicDrivenLayout.AbstractComponent}
SchematicDrivenLayout.create_component(::Type{T}, ::DeviceLayout.SchematicDrivenLayout.ParameterSet) where {T <: DeviceLayout.SchematicDrivenLayout.AbstractComponent}
SchematicDrivenLayout.set_parameters(::DeviceLayout.SchematicDrivenLayout.AbstractComponent, ::Pair{<:Any, Symbol}...)
```
