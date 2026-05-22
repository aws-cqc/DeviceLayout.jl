# [Autofill](@id concept-autofill)

It's common to fill empty areas of a layout with a repeating small structure. For example, a dummy fill can be used to control pattern density, or ground plane holes can be used for flux trapping in superconducting circuits. The geometry interface provides the [`halo`](@ref) function for generating exclusion areas for structures and entities, as well as the [`autofill!`](@ref) method for placing references on grid points that fall outside exclusion areas.

Components can implement their own `halo` function to customize or simply to speed up exclusion area calculation. A common pattern is to specialize [`footprint`](@ref), which should return a single `GeometryEntity` covering the entire component, and then delegate `halo` to [`SchematicDrivenLayout.footprint_halo`](@ref):

```julia
DeviceLayout.footprint(comp::MyComponent) = circle_polygon(comp.outer_radius + comp.gap)
DeviceLayout.halo(comp::MyComponent, d, d_i=nothing; kw...) =
    SchematicDrivenLayout.footprint_halo(comp, d, d_i; kw...)
```

`footprint_halo` offsets the footprint once and replicates it across all matching layers in the component, handling memoization and layer filtering automatically. This avoids the per-element, per-layer Clipper calls of the default `halo`.

Custom footprints can be validated with [`DeviceLayout.has_valid_footprint`](@ref).

See [API Reference: Autofill](@ref api-autofill).
