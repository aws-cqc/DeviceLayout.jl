# Components

```@docs
SchematicDrivenLayout.AbstractComponent
SchematicDrivenLayout.Component
```

## Defining components

The recommended way to define a component is the `@compdef` macro, which specifies
the parameters names and defaults as part of the struct definition. It creates the keyword
constructor (like `Base.@kwdef` does) as well as the `default_parameters` method that are
required to allow the above interface to work.

```@docs
SchematicDrivenLayout.@compdef
```

An `AbstractComponent` should include a `name` field, and also implement the following specializations:

  - `_geometry!(cs::CoordinateSystem, comp::MyComponent)`:
    Render the component's geometry to a `CoordinateSystem` `cs`.
  - `hooks(::MyComponent)`: a `NamedTuple` of `Hook`s and/or `Vector{Hook}`s that specify
    where and how attachments are made

Validation or reconciling of parameters should be done in an inner constructor. At least one
inner constructor should accept arguments in the
same form as the default inner constructor (i.e. one positional argument per field) in
order to function correctly with the keyword outer constructor.

An `AbstractComponent` may also override `GeometryStructure` methods like `footprint` and `halo`.

The methods `check_rotation` and `allowed_rotation_angles` can be implemented to enforce a requirement for the orientation of the component in the global coordinate system:

```@docs
SchematicDrivenLayout.check_rotation
SchematicDrivenLayout.allowed_rotation_angles
```

Finally, an `AbstractComponent` may define methods to specify default hooks for fusion with other components in a schematic:

  - `matching_hooks(::MyComponent1, ::MyComponent2)`
  - `matching_hooks(::MyComponent2, ::MyComponent1)`
  - `matching_hook(::MyComponent1, hook1::Symbol, ::MyComponent2)`
  - ...

Methods for both argument orders in `matching_hooks` should generally be defined. Although
`SchematicGraph`s are undirected, certain components may treat the different argument orders
differently. For example, `matching_hooks(::Path, <:AbstractComponent)` will attach the
second argument to the endpoint hook `:p1` on the `Path`, while the reverse order
will attach the start point hook `:p0` to the first argument.

```@docs
SchematicDrivenLayout.matching_hooks
SchematicDrivenLayout.matching_hook
```

Components support the following API:

```@docs
SchematicDrivenLayout.geometry
SchematicDrivenLayout.hooks
SchematicDrivenLayout.default_parameters
halo(::SchematicDrivenLayout.AbstractComponent, ::Any, ::Any)
SchematicDrivenLayout.name(::SchematicDrivenLayout.AbstractComponent)
SchematicDrivenLayout.non_default_parameters
SchematicDrivenLayout.parameters
SchematicDrivenLayout.parameter_names
```

Components can be created by several methods. In addition to the keyword constructor,
the `create_component` and `set_parameters` method allow the use of a set of base parameters or a prototype component to effectively provide a new set of defaults. The `@component` macro can also be used with either a component type or an instance.

```@docs
SchematicDrivenLayout.@component
SchematicDrivenLayout.create_component
SchematicDrivenLayout.set_parameters
```

## Built-in components

We provide some other predefined components that may be generally useful.

```@docs
SchematicDrivenLayout.ArrowAnnotation
SchematicDrivenLayout.BasicComponent
SchematicDrivenLayout.GDSComponent
SchematicDrivenLayout.Spacer
SchematicDrivenLayout.WeatherVane
```

## Paths as components

Another component already showed up in geometry-level layout: [`DeviceLayout.Path`](@ref) is an `AbstractComponent` with hooks `p0` and `p1` corresponding to its start and end. `Path` supports the interface described above and can be added directly to a schematic just like any other component.

```@docs
DeviceLayout.hooks(::Path) 
```

Recall that `Path` supports a geometry-level [`attach!`](@ref DeviceLayout.attach!(::Path{T}, ::DeviceLayout.GeometryReference{T}, ::DeviceLayout.Coordinate) where {T}) method that can place references to other structures along it. It also supports a schematic-level [`attach!`](@ref SchematicDrivenLayout.attach!(::SchematicDrivenLayout.SchematicGraph,
::S,
::Pair{T, Symbol},
::DeviceLayout.Coordinate
) where {S <: SchematicDrivenLayout.ComponentNode, T <: SchematicDrivenLayout.ComponentNode}) with a similar syntax, which positions components along the path by defining an edge in the schematic graph.

## Composite components

A "composite" component is one that's at least partly made up of other components. Nothing stops you from "baking in" subcomponents in your component's `geometry` function by deriving parameters and getting geometries for those subcomponents yourself. You could even construct a `SchematicGraph` then `plan`,
`check!`, and `build!` it to get a coordinate system of subcomponents fused together. But in that case, your top-level schematic won't know anything about what's inside your composite component.

As an alternative, we define `abstract type AbstractCompositeComponent <: AbstractComponent`, which is minimally a `Component` with a `graph(cc::MyCompositeComponent)` method that produces a `SchematicGraph` of the subcomponents it's made from, such that the composite component's geometry is just
`build!(plan(graph(cc)))`.

SchematicDrivenLayout provides a concrete composite component: `BasicCompositeComponent`, which is really just a graph defined by the user and wrapped in a `Component`. It maps parameters and hook names exposed by the composite component by prefixing their names with `_i_`, where `i` is the index of the subcomponent node in `graph(cc)`.

A new subtype of `CompositeComponent` can be defined to use a custom reparameterization and mapping of hook names in the subgraph.

```@docs
SchematicDrivenLayout.AbstractCompositeComponent
SchematicDrivenLayout.CompositeComponent
SchematicDrivenLayout.BasicCompositeComponent
SchematicDrivenLayout.components(::SchematicDrivenLayout.CompositeComponent)
SchematicDrivenLayout.filter_parameters
SchematicDrivenLayout.flatten(::SchematicDrivenLayout.SchematicGraph)
SchematicDrivenLayout.graph
SchematicDrivenLayout.map_hooks
```

## Modifying components

Sometimes we want to use components in ways the component designer didn't predict.
For example, we might want to draw a `Qubit` component on the top chip in a flipchip assembly,
but the metadata in the generated geometry corresponds to the bottom chip.

There are a couple ways to do this concisely. One is to take a `Qubit` and run
[`map_metadata!`](@ref) on it:

```julia
q = Qubit()
map_metadata!(q, facing)
```

This applies [`facing`](@ref SchematicDrivenLayout.facing) to each piece of metadata in `geometry(q)`. Any function
of metadata that returns metadata can be used as the second argument, so if you only
wanted to flip the `:jj` layer, you could write
`map_metadata!(q, m -> layer(m) == :jj ? facing(m) : m)`.

Note that `geometry(q)` is associated only with `q`, and changes to it are not tracked
elsewhere. If, in a later step, you were to apply junction width corrections by replacing `q`
with `q2 = typeof(q)(; parameters(q)..., jj_width=new_width)`, then `q2` would not
be on the flip chip.

For larger changes, we can make a new `Component` type. Rather than copy the `Qubit`
definition and find-and-replace its metadata, we can use the `@variant` macro.

```julia
@variant FlipchipQubit Qubit map_meta = facing
fq = FlipchipQubit()
all(level.(element_metadata(geometry(fq))) .== 2)
```

This creates a new type, `FlipchipQubit`, and automatically defines the required
methods for `Component` implementation using the `Qubit` implementation. It has the same
`default_parameters`, `hooks`, and almost the same `_geometry!`. Since we supplied
the optional keyword `map_meta`, the geometry method for the new type creates a `Qubit` and
then applies `facing` to each element (and referenced structure, recursively), as in the
`map_metadata!` example above. But unlike with using `map_metadata!` on a single `Qubit` instance,
you can replace `fq` with another `typeof(fq)` without losing the level information.

You can also go further with manual modifications. You could add a cutout
on the bottom chip, along with a parameter to control the size of the cutout:

```julia
@variant CutoutFlipchipQubit Qubit map_meta = facing new_defaults = (; cutout_margin=20μm)
function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, fq::CutoutFlipchipQubit)
    _geometry!(cs, base_variant(fq)) # base_variant gives you the equivalent `Qubit`
    map_metadata!(cs, facing)
    # The above lines are what we would get from @variant Qubit map_meta=facing
    # Below, we add a cutout on the bottom chip
    return place!(cs, offset(bounds(cs), parameters(fq).cutout_margin)[1], BASE_NEGATIVE)
end
```

Note that if `Qubit` were a `CompositeComponent`, we would have to use the macro
`@composite_variant` instead.

```@docs
SchematicDrivenLayout.base_variant
SchematicDrivenLayout.flipchip!
SchematicDrivenLayout.@variant
SchematicDrivenLayout.@composite_variant
```
