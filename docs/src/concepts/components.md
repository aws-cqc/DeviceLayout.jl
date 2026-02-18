```@meta
CurrentModule = SchematicDrivenLayout
```

# [Components](@id concept-components)

Components are the reusable building blocks of [schematic-driven design](./schematic_driven_design.md).

See [API Reference: Components](@ref api-components) and the [Building a Component](../tutorials/building_a_component.md) tutorial.

## Anatomy of a Component

Every component has:

1. **Type**: A subtype of `AbstractComponent <: GeometryStructure`
2. **Parameters**: Configurable values with defaults
3. **Geometry**: A coordinate system returned by `geometry`
4. **Hooks**: Connection points returned by `hooks`

"Simple" (non-composite) components are defined with `@compdef struct MyComponent <: Component` and implement `_geometry!` and `hooks` methods.
A complete component definition looks like this:

```@example
using DeviceLayout, .PreferredUnits, .SchematicDrivenLayout

@compdef struct MyComponent <: Component
    name = "my_component"   # Parameters with defaults
    width = 100μm
    height = 50μm
end

function SchematicDrivenLayout._geometry!(cs::CoordinateSystem, comp::MyComponent)
    place!(cs, Rectangle(comp.width, comp.height), :layer)
end

function SchematicDrivenLayout.hooks(comp::MyComponent)
    return (; p0 = PointHook(Point(0nm, 25μm), 180°))
end

# Demonstrate basic API
comp = MyComponent(height=100μm)
println("comp: $comp")
println("parameters(comp): $(parameters(comp))")
println("hooks(comp): $(hooks(comp))")
println("geometry(comp): $(geometry(comp))")
```

There are a few details worth pointing out above:

- We subtyped `Component` rather than `AbstractComponent` out of convenience, to avoid worrying about the coordinate type parameter. `Component` is actually an alias for `AbstractComponent{typeof(1.0UPREFERRED)}`.
- We defined `SchematicDrivenLayout._geometry!` rather than just `_geometry!`, and likewise for `hooks`. In Julia, when we extend an existing function with a new method for our custom type, we need to specify the module it comes from. If we just define `function _geometry!(...)`, then DeviceLayout won't know to call that method internally. Making this mistake will result in an empty geometry and no hooks, since SchematicDrivenLayout will fall back on generic implementations of those methods.
- `hooks` returns a `NamedTuple` with a single element using a leading semicolon. If we wrote `(p0 = PointHook(...))`, then this would be interepreted as a variable assignment. Our [style guide](./styleguide.md) recommends defining literal `NamedTuple`s with a leading semicolon.

`@compdef` creates the keyword constructor with defaults, like [`Base.@kwdef`](https://docs.julialang.org/en/v1/base/base/#Base.@kwdef) does, as well as a `default_parameters` method. It also creates a private field for geometry, which is computed the first time `geometry` is called and stored thereafter. Parameter defaults should not depend on the values of other parameters. Validation or reconciling of parameters should be done in an inner constructor. At least one
inner constructor should accept arguments in the
same form as the default inner constructor (i.e. one positional argument per field) in
order to function correctly with the keyword outer constructor. 

Because `AbstractComponent{T}` is a subtype of `GeometryStructure{T}`, components support the [Structure API](@ref api-geometrystructure) as well as general geometry methods like `bounds`. Most of those methods are not implemented by the component but are instead forwarded to the `CoordinateSystem` containing the component's geometry (that is, `bounds(mycomponent) = bounds(geometry(mycomponent))`). One exception is `name`: A component's name is not necessarily unique, but the name of `geometry(component)` is set using `uniquename(name(component))`.

An `AbstractComponent` may override some `GeometryStructure` methods like `footprint` and `halo` when customization or efficient computation is required (see [Concepts: Autofill](@ref concept-autofill)).

The methods [`check_rotation`](@ref) and [`allowed_rotation_angles`](@ref) can be implemented to enforce a requirement for the orientation of the component in the global coordinate system (checked by `check!(schematic)` by default). Other schematic design rules can be implemented with a similar pattern: a "trait" method that says that the rule applies, and a second method used to evaluate the rule.

Finally, an `AbstractComponent` may define [`matching_hooks`](@ref) methods to specify default hooks for fusion with other components in a schematic. Methods for both argument orders in `matching_hooks` should generally be defined. Although
`SchematicGraph`s are undirected, certain components may treat the different argument orders
differently. For example, `matching_hooks(::Path, <:AbstractComponent)` will attach the
second argument to the endpoint hook `:p1` on the `Path`, while the reverse order
will attach the start point hook `:p0` to the first argument.

## Paths as components

While [`Path`](./paths.md) is a common structure in geometry-level layout, it is also an `AbstractComponent` with hooks `p0` and `p1` corresponding to its start and end. Its geometry is a `CoordinateSystem` with a reference to itself. A `Path` can be added directly to a schematic just like any other component.

Recall that `Path` supports a geometry-level [`attach!`](@ref DeviceLayout.attach!(::Path{T}, ::DeviceLayout.GeometryReference{T}, ::DeviceLayout.Coordinate) where {T}) method that can place references to other structures along it. At the schematic-level, it supports an analogous [`attach!`](@ref SchematicDrivenLayout.attach!(::SchematicDrivenLayout.SchematicGraph,
::S,
::Pair{T, Symbol},
::DeviceLayout.Coordinate
) where {S <: SchematicDrivenLayout.ComponentNode, T <: SchematicDrivenLayout.ComponentNode}) with a similar syntax, which positions components along the path by defining an edge in the schematic graph.

## [Composite Components](@id concept-composite-components)

A "composite" component is one that's made up of other components. Nothing stops you from "baking in" subcomponents in a "simple" component's `_geometry!` function by deriving parameters and placing geometries for those subcomponents yourself. You could even construct a `SchematicGraph` then `plan`,
`check!`, and `build!` it to get a coordinate system of subcomponents fused together. But in that case, your top-level schematic won't know anything about what's inside your composite component.

DeviceLayout provides `abstract type AbstractCompositeComponent <: AbstractComponent` for components that are fully defined by their own `SchematicGraph`. Schematic methods like [`SchematicDrivenLayout.find_nodes`](@ref) are able to search within composite components in a graph (optionally restricted to a recursive depth controlled by keyword argument).

`SchematicDrivenLayout` provides one built-in composite component: `BasicCompositeComponent`, which is simply a graph defined by the user and wrapped in a `Component`. It maps parameters and hook names exposed by the composite component by prefixing their names with `_i_`, where `i` is the index of the subcomponent node in `graph(mycomposite)`.

You may define your own `CompositeComponent` when you want to reparameterize the subcomponents in terms of higher-level parameters or to expose hooks of the internal graph externally. This is done by implementing `_build_subcomponents`, `_graph!`, and `map_hooks` methods, with a minimal implementation that looks like this:

```julia
@compdef struct MyComposite <: CompositeComponent
    # ...
end

function SchematicDrivenLayout._build_subcomponents(comp::MyComposite)
    # ... return a Tuple of subcomponents
end

function SchematicDrivenLayout._graph!(
    g::SchematicGraph,
    comp::MyComposite,
    subcomps::NamedTuple # from `_build_subcomponents` with component names as keys
)
    # ... Add/fuse `subcomps` to graph `g`
    # Order in which components are added determines `graph_index` used in `map_hooks`
end

function SchematicDrivenLayout.map_hooks(comptype::Type{MyComposite})
    return Dict( # Map internal hooks to external hooks
        (graph_index => :internal) => :external, # ...
    )
end
```

## Creating and Modifying Components

Components can be instantiated by several methods. In addition to the keyword constructor,
a component instance can be called like a function, acting as a "template" that effectively provides a new set of defaults. The [`@component`](@ref SchematicDrivenLayout.@component) macro is convenient for automatically setting the name of a component to match its variable name, and can also be used with either a component type or a template instance:

```julia
@component mycomp = MyComponent begin
    width = 50μm
    # other parameters...
end
@component mycomp2 = mycomp begin
    height = 100μm
end
println(mycomp.name == "mycomp")
println(mycomp.param1 == mycomp2.param1)
```

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

Variants are useful for quick, ad-hoc modifications, but if a variant is needed consistently, consider adding new parameters or creating a new explicit component type.

## See Also

- [Tutorial: Building a Component](../tutorials/building_a_component.md)
- [Tutorial: Composite Components](../tutorials/composite_components.md)
- [API Reference: Components](@ref api-components)
- [API Reference: Hooks](@ref api-hooks)
- [Component Style Guide](./styleguide.md)