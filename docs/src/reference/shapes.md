```@meta
DocTestSetup = quote
    using Unitful, DeviceLayout
    using Unitful: °
end
```

# Shape library

Examples on this page assume you have done `using DeviceLayout, DeviceLayout.PreferredUnits, FileIO`.

## Simple shapes

A library of simple shapes is available from the SimpleShapes module.
All of these functions are exported by the top-level DeviceLayout module and
are directly accessible to the user.

```@docs
    circular_arc
    draw_pixels
    hatching_unit
    radial_cut
    radial_stub
    simple_cross
    simple_ell
    simple_tee
```

Example:

```@example 7
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO # hide
c = Cell("main", nm)
p = radial_cut(20μm, π / 2, 5μm)
render!(c, p, GDSMeta(1))
save("radial_cut.svg", flatten(c));
nothing; # hide
```

```@raw html
<img src="../radial_cut.svg" style="width:2in;"/>
```

Example:

```@example 8
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO # hide
c = Cell("main", nm)
p = radial_stub(20μm, π / 2, 5μm, 1μm)
render!(c, p, GDSMeta(1))
save("radial_stub.svg", flatten(c));
nothing; # hide
```

```@raw html
<img src="../radial_stub.svg" style="width:2in;"/>
```

## Compound shapes

We also provide methods for a few "compound shapes" that render multiple entities to a coordinate system rather than return a single entity.

```@docs
    checkerboard!
    grating!
    interdigit!
```

Example for `checkerboard!`:

```@example 1
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO # hide
c = Cell("main", nm)
checkerboard!(c, 20μm, 10, false, GDSMeta(2))
checkerboard!(c, 20μm, 10, true, GDSMeta(3))
save("checkers.svg", flatten(c));
nothing; # hide
```

```@raw html
<img src="../checkers.svg" style="width:2in;"/>
```

Example for `grating!`:

```@example 2
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO # hide
c = Cell("main", nm)
grating!(c, 100nm, 100nm, 5μm, GDSMeta(3))
save("grating.svg", flatten(c));
nothing; # hide
```

```@raw html
<img src="../grating.svg" style="width:2in;"/>
```

Simple usage for `interdigit!`:

```@example 3
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO # hide
fingers = Cell("fingers", nm)
wide, length, fingergap, fingeroffset, npairs, skiplast = 1μm, 20μm, 1μm, 3μm, 5, true
interdigit!(fingers, wide, length, fingergap, fingeroffset, npairs, skiplast, GDSMeta(5))
save("fingers_only.svg", flatten(fingers));
nothing; # hide
```

```@raw html
<img src="../fingers_only.svg" style="width:2in;"/>
```

Example of how to make an interdigitated capacitor inline with a feedline:

```@example 4
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO # hide
c = Cell("main", nm)
p = Path(μm)
trace, gap = 17μm, 3μm
straight!(p, 50μm, Paths.CPW(trace, gap))
straight!(p, 23μm, Paths.NoRender())
straight!(p, 50μm, Paths.CPW(trace, gap))
fingers = Cell("fingers", nm)
wide, length, fingergap, fingeroffset, npairs, skiplast = 1μm, 20μm, 1μm, 3μm, 5, true
interdigit!(fingers, wide, length, fingergap, fingeroffset, npairs, skiplast, GDSMeta(5))
finger_mask =
    Rectangle(width(bounds(fingers)), height(bounds(fingers)) + 2 * gap) - Point(0μm, gap)
inverse_fingers = Cell("invfingers", nm)
plgs = difference2d(finger_mask, elements(fingers))
render!(inverse_fingers, plgs, GDSMeta(0))
attach!(
    p,
    CellReference(inverse_fingers, Point(0μm, -upperright(bounds(fingers)).y / 2)),
    0μm,
    i=2
)
render!(c, p, GDSMeta(0))
save("fingers.svg", flatten(c));
nothing; # hide
```

```@raw html
<img src="../fingers.svg" style="width:4in;"/>
```
