# Units

DeviceLayout.jl uses [Unitful.jl](http://painterqubits.github.io/Unitful.jl/stable/) to support writing code with explicit units.

In general, geometric types are parameterized by a [`coordinatetype`](@ref), which is either a `Real` or a `Unitful.Length` (for example, `typeof(1.0nm)`). We want to ensure that unitful numbers in a geometry have a
common representation, allowing more efficient manipulation and avoiding
unnecessary conversions and compilations.

Recall the quick-start example from the home page:

```julia
using DeviceLayout, DeviceLayout.PreferredUnits, FileIO

cr = Cell("rect", nm)
r = centered(Rectangle(20μm, 40μm))
render!(cr, r, GDSMeta(1, 0))
p = Path(μm)
sty = launch!(p)
straight!(p, 500μm, sty)
turn!(p, π / 2, 150μm)
straight!(p, 500μm)
launch!(p)
cp = Cell("pathonly", nm)
render!(cp, p, GDSMeta(0))
turnidx = Int((length(p) + 1) / 2) - 1 # the first straight segment of the path
simplify!(p, turnidx .+ (0:2))
attach!(
    p,
    CellReference(cr, Point(0.0μm, 0.0μm)),
    (40μm):(40μm):((pathlength(p[turnidx])) - 40μm),
    i=turnidx
)
c = Cell("decoratedpath", nm)
render!(c, p, GDSMeta(0))
```

```@raw html
<img src="../units.svg" style="width: 3in;"/>
```

The example begins with `using DeviceLayout.PreferredUnits`, which enables the unqualified use of
the following units: `pm`, `nm`, `μm`, `mm`, `cm`, `dm`, `m`. (By unqualified we
mean that the symbols are imported into the calling namespace and do not need to be prefixed
with a module name. `using DeviceLayout` also gives you `°` and `rad` for angles.) `DeviceLayout.PreferredUnits` is, by default, an alias for `DeviceLayout.PreferNanometers`. This means that when adding length units together, if the units don't agree, the result
will be in nanometers.

You can instead do `using DeviceLayout.PreferMicrons` if you want the
result to default to microns. This is simple and effective, but does not enforce consistency across large projects like process design kits (PDKs) or layout scripts with multiple modules that might accidentally import units in different ways. Accordingly, DeviceLayout.jl provides a slightly more sophisticated method to specify alternative preferences using a configuration setting applied at compilation time, which is described below.

### Unit preferences

By default, DeviceLayout will be compiled with `using .PreferNanometers` internally. If you then import units from DeviceLayout

```julia
using DeviceLayout.PreferredUnits
```

or, more explicitly,

```julia
import DeviceLayout: nm, μm, mm #, ...
```

you get the unqualified units as described above. This also defines `const UPREFERRED = DeviceLayout.PreferNanometers.nm`. In the handful of places that `UPREFERRED` appears in DeviceLayout.jl (convenience constructors and type aliases allowing users to omit explicit unit specification), it'll then be `ContextUnits` that prefers to be converted to nanometers.

If you want different behavior, then the recommended practice is to specify a unit preference as a package preference and then import unit symbols from DeviceLayout. That is, if you put a file called `LocalPreferences.toml` in the root of a project directory with

```
[DeviceLayout]
units = "PreferMicrons"
```

then DeviceLayout will be compiled with `using .PreferMicrons` internally. (This is accomplished using [Preferences.jl](https://juliapackaging.github.io/Preferences.jl/stable/).) That means that `DeviceLayout.nm` and so on will prefer to be converted to microns, and `const UPREFERRED = DeviceLayout.μm; const PreferredUnits = PreferMicrons`.

Similarly, if we have the preference `units = "NoUnits"`, then DeviceLayout uses `import Unitful: nm, ...` and `const UPREFERRED = Unitful.NoUnits; const PreferredUnits = PreferNoUnits` internally.

```@docs
    DeviceLayout.UPREFERRED
    DeviceLayout.PreferMicrons.UPREFERRED
    DeviceLayout.PreferNoUnits.UPREFERRED
```

You can also set the preference in `Project.toml` with the following lines:

```
[preferences.DeviceLayout]
units = "PreferMicrons"
```

Typically, `LocalPreferences.toml` will be ignored by version control (that is, listed in `.gitignore`), so you'll use it to set preferences that are only meant to be used locally. If you want preferences to be used by anyone cloning and instantiating your project, then you'll put them in `Project.toml`.

For convenience, you can use `DeviceLayout.set_unit_preference!` to add the preference to either `LocalPreferences.toml` or `Project.toml`.

```@docs
    DeviceLayout.set_unit_preference!
```

Note that only preferences of the active project are applied. For example, if you have a separate package defining your process design kit (PDK), adding the preference to `Project.toml` does not mean that any project that uses the PDK will inherit that preference. If a PDK is meant to be used with units, you can have it set the preference during package setup:

```julia
module MyPDK
using DeviceLayout

function __init__()
    return DeviceLayout.set_unit_preference!("PreferNanometers"; local_only=false)
end
# ...
end
```

Because the preference is used at compile time, Julia will have to be restarted if the preference was not already set.

### Example without using units

While units are recommended, it is possible to use DeviceLayout.jl without units at
all for compatibility and laziness reasons.

**If you do not provide units, all values are presumed to be in microns.** The syntax
is otherwise the same:

```@example
using DeviceLayout, FileIO

cr = Cell{Float64}("rect") # If unit preference were `NoUnits`, we wouldn't need `{Float64}`
r = centered(Rectangle(20, 40))
render!(cr, r, GDSMeta(1))

p = Path{Float64}()
sty = launch!(p)
straight!(p, 500, sty)
turn!(p, π / 2, 150)
straight!(p, 500)
launch!(p)
cp = Cell{Float64}("pathonly")
render!(cp, p, GDSMeta(0))

turnidx = Int((length(p) + 1) / 2) - 1 # the first straight segment of the path
simplify!(p, turnidx .+ (0:2))
attach!(
    p,
    CellReference(cr, Point(0.0, 0.0)),
    40:40:((pathlength(p[turnidx])) - 40),
    i=turnidx
)
c = Cell{Float64}("decoratedpath")
render!(c, p, GDSMeta(0))
flatten(c) # just show using default colors
```

Maintaining unitless functionality alongside unitful functionality takes some care, so you may encounter errors when using unitless geometries, particularly with less mature features. Please file an issue if that happens.

!!! tip
    
    It's usually not too hard to write library code that works with or without units. Often it's as simple as making sure you're not overly strict with type annotations and not writing literal coordinate values. For example, use [`DeviceLayout.Coordinate`](@ref) rather than `Unitful.Length` if you also want to accept `Real` values, and use the [`zero`](https://docs.julialang.org/en/v1/base/numbers/#Base.zero) function rather than `0.0nm`.

### Angles

Throughout the interface, users can provide angles as unitless real numbers, which will be interpreted as radians, or as Unitful numbers using degrees (`°`, which can be written in the REPL or in VS Code by typing `\degree` and hitting the Tab key) or radians (`rad`), both exported by DeviceLayout.jl. Angles are generally stored internally as degrees.

### More on units

You cannot mix and match unitful and unitless numbers (the latter are not presumed to be
in microns in this case).

When you specify the units for a `Cell`, you are specifying the coordinate type of its elements. Separately, the cell has a database unit stored in its `dbscale` field, which defaults to 1 nm. Anything
rendered into this cell will be discretized into integer multiples of the database unit upon saving to the GDSII format.
This means that if the specified unit is `nm`, nothing smaller than 1 nm can be represented accurately. Nonetheless,
this is typically a satisfactory choice for superconducting devices. If you are using
a unitless `Cell`, the database unit will be 0.001 (that is, 1 nm).

`μ` can be input in the REPL or in VS Code by typing `\mu` and hitting the Tab key. Some people find it convenient to define `const um = DeviceLayout.μm` in their scripts.
