# How to Create a CPW

This guide shows how to create coplanar waveguide (CPW) structures.

## Basic CPW Path

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

# Create path with CPW style (trace width, gap width)
p = Path(μm)
straight!(p, 500μm, Paths.CPW(10μm, 6μm))
```

## CPW with Turns

```julia
p = Path(μm)
straight!(p, 200μm, Paths.CPW(10μm, 6μm))
turn!(p, 90°, 100μm)   # 90° turn, 100μm radius
straight!(p, 200μm)
```

## CPW with Launchers

```julia
p = Path(μm)
sty = launch!(p)                    # Add launcher
straight!(p, 500μm, sty)            # Continue with launcher style
turn!(p, 90°, 100μm)
straight!(p, 300μm)
launch!(p)                          # End launcher
```

## Render to Cell

```julia
cell = Cell("cpw", nm)
render!(cell, p, GDSMeta(0))
```

## See Also

- [Add Tapers](add_tapers.md) - Transitioning between styles
- [Tutorial: Working with Paths](../../tutorials/working_with_paths.md)
