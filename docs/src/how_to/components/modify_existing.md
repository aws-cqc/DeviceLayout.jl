# How to Modify Existing Components

This guide shows how to customize existing components without rewriting them.

## Change Parameters

```julia
using DeviceLayout.SchematicDrivenLayout

# Create with modified parameters
original = MyCapacitor()
modified = MyCapacitor(finger_length=200μm, num_fingers=8)

# Or use set_parameters
modified = set_parameters(original, finger_length=200μm)
```

## Map Metadata (Layer Changes)

```julia
comp = MyQubit()

# Change all layers to flip chip (level 2)
map_metadata!(comp, facing)

# Change specific layers
map_metadata!(comp, m -> layer(m) == :junction ? facing(m) : m)
```

## Create Variants

Use `@variant` for permanent modifications:

```julia
# Create a flipchip version
@variant FlipchipQubit MyQubit map_meta = facing

# Add new parameters
@variant ExtendedQubit MyQubit new_defaults = (; extra_param=10μm)

# Custom geometry modifications
@variant CustomQubit MyQubit
function SchematicDrivenLayout._geometry!(cs, q::CustomQubit)
    _geometry!(cs, base_variant(q))  # Original geometry
    # Add modifications here
    place!(cs, Rectangle(50μm, 50μm), :extra_layer)
end
```

## For Composite Components

```julia
@composite_variant FlipchipTransmon ExampleTransmon map_meta = facing
```

## See Also

- [Tutorial: Building a Component](../../tutorials/building_a_component.md)
- [Components Reference](@ref)
