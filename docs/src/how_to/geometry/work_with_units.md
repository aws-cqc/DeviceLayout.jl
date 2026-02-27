# How to Work with Units

This guide shows how to use units effectively in DeviceLayout.jl.

## Setting Up Units

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Available units: pm, nm, μm, mm, cm, dm, m
# Available angles: °, rad
```

## Creating Geometry with Units

```julia
# Lengths with units
rect = Rectangle(100μm, 50μm)
circle = Circle(25μm)

# Points with units
p = Point(10μm, 20μm)

# Angles
rotation = Rotation(45°)
```

## Unit Conversions

```julia
# Convert between units
length_nm = 1000nm
length_um = uconvert(μm, length_nm)  # 1.0 μm

# Mixed units auto-convert to preferred unit
sum = 1μm + 500nm  # Result in nm (default preference)
```

## Changing Unit Preference

Set globally for your project (requires restart):

```julia
using DeviceLayout
DeviceLayout.set_unit_preference!("PreferMicrons")
```

Or in `LocalPreferences.toml`:
```toml
[DeviceLayout]
units = "PreferMicrons"
```

## Unitless Mode

For backward compatibility:

```julia
# Unitless values assumed to be in microns
rect = Rectangle(100.0, 50.0)  # 100μm × 50μm

cell = Cell{Float64}("unitless")
```

## See Also

- [Units Concept](@ref) for detailed explanation
- [Installation](../../getting_started/installation.md) for setup
