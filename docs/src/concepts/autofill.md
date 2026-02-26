# [Autofill](@id concept-autofill)

It's common to fill empty areas of a layout with a repeating small structure. For example, a dummy fill can be used to control pattern density, or ground plane holes can be used for flux trapping in superconducting circuits. The geometry interface provides the [`halo`](@ref) function for generating exclusion areas for structures and entities, as well as the [`autofill!`](@ref) method for placing references on grid points that fall outside exclusion areas.

See [API Reference: Autofill](@ref api-autofill).

Components can implement their own `halo` function to customize or simply to speed up exclusion area calculation. A common pattern is to specialize [`footprint`](@ref), which should return a single `GeometryEntity` covering the entire component, and use that as the basis of the halo. For example:

```julia
function DeviceLayout.footprint(comp::MyComponent)
    return fast_computation_of_bounding_entity(comp) # Avoid drawing entire component
end

function DeviceLayout.halo(
    comp::MyComponent,
    outer_delta,
    inner_delta=nothing;
    only_layers=[],
    ignore_layers=[],
    memoized_halos=Dict{GeometryStructure, GeometryStructure}()
)
    # Boilerplate to allow reuse of halos of identical structures
    haskey(memoized_halos, comp) && return memoized_halos[comp]
    halo_cs = CoordinateSystem{coordinatetype(comp)}(uniquename("halo_" * name(comp)))
    memoized_halos[comp] = halo_cs
    # Draw halo in `halo_cs`
    halo_layer = METAL_NEGATIVE # Or whatever layer(s) are relevant
    if layer_included(halo_layer, only_layers, ignore_layers)
        place!(halo_cs, halo(footprint(comp), outer_delta, inner_delta), halo_layer)
    end
    return halo_cs
end
```
