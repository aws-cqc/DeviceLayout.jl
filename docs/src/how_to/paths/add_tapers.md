# How to Add Tapers

This guide shows how to create smooth transitions between different path styles.

## Automatic Tapers

Use `Paths.Taper()` to auto-detect transition:

```julia
using DeviceLayout, DeviceLayout.PreferredUnits

p = Path(μm)
straight!(p, 100μm, Paths.Trace(5μm))
straight!(p, 50μm, Paths.Taper())      # Auto-taper
straight!(p, 100μm, Paths.Trace(15μm))
```

## Taper Between Trace and CPW

```julia
p = Path(μm)
straight!(p, 100μm, Paths.Trace(10μm))
straight!(p, 50μm, Paths.Taper())
straight!(p, 100μm, Paths.CPW(10μm, 6μm))
```

## Explicit Tapers

For precise control:

```julia
# TaperTrace: explicit start and end widths
straight!(p, 50μm, Paths.TaperTrace(5μm, 15μm))

# TaperCPW: explicit trace and gap transitions
straight!(p, 50μm, Paths.TaperCPW(5μm, 10μm, 3μm, 6μm))
```

## Tapers in Turns

Tapers work with turns too:

```julia
p = Path(μm)
straight!(p, 100μm, Paths.Trace(5μm))
turn!(p, 90°, 50μm, Paths.Taper())
straight!(p, 100μm, Paths.Trace(10μm))
```

## See Also

- [Create a CPW](create_cpw.md)
- [Paths Reference](@ref)
