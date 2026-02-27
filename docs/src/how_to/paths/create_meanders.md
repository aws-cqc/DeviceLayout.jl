# How to Create Meanders

This guide shows how to create meandering paths to fit long resonators in limited space.

## Basic Meander

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

p = Path(μm)
straight!(p, 50μm, Paths.CPW(10μm, 6μm))
meander!(p, 500μm, 100μm, 50μm)  # length, height, turn radius
straight!(p, 50μm)
```

Parameters:
- **length**: Total path length to achieve
- **height**: Vertical extent of the meander
- **turn radius**: Radius for the U-turns

## Controlling Meander Direction

```julia
# Meander going up
meander!(p, 500μm, 100μm, 50μm)

# Meander going down (negative height)
meander!(p, 500μm, -100μm, 50μm)
```

## Multiple Meanders

```julia
p = Path(μm)
straight!(p, 50μm, Paths.CPW(10μm, 6μm))
meander!(p, 300μm, 80μm, 30μm)
straight!(p, 100μm)
meander!(p, 300μm, -80μm, 30μm)  # Opposite direction
straight!(p, 50μm)
```

## See Also

- [Create a CPW](create_cpw.md)
- [Paths Reference](@ref)
