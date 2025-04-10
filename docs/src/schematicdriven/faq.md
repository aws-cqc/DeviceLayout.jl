# Troubleshooting & FAQ

**Is there a way to not render a node in the SchematicGraph?**

Rendering with a `LayoutTarget` will skip all entities with the special metadata `DeviceLayout.NORENDER_META = SemanticMeta(:norender)`, so there's a workaround: Try running `map_metadata!(component(mynode), (_) -> DeviceLayout.NORENDER_META)` before calling `build!` or `render!`.

**How do I attach components like readout resonators along a route in the schematic?**

If you have an existing node created by `route!`, you can attach `CoordinateSystemReferences` with the function `attach!(r::RouteComponent, c::CoordSysRef, t::Coordinate; location::Int=0)` and it works like attaching things to a `Path`. Right now there's no way to attach a Component to a `RouteComponent` so that it becomes part of the schematic. For that, use a `Path` with `attach!(::SchematicGraph, ...)`.

**How do I attach components like readout resonators along a path in the schematic?**

I recommend creating a straight Path, then attaching your component to that. For example:

```julia
pa = Path(
    Point(0μm, 0μm),
    α0=0°,
    metadata=SemanticMeta(:metal_negative),
    name=uniquename("coupseg")
)
straight!(pa, 250μm, cpw_style)

coupling_seg_node = add_node!(g, pa)
rres_node = add_node!(g, readout_resonator)
attach!.(
    g,
    segnode,
    rres_node => :readout_line,
    pathlength(SchematicDrivenLayout.component(segnode).path) / 2,
    i=1,
    location=1
)
# ... then fuse/route these to other nodes as usual
```

**What's with all the semicolons?**

Semicolons are used in Julia in a few places related to key-value pairs:

  - In function definitions, separating positional arguments from keyword arguments.
    
      + If there are no positional arguments, it's still necessary to start with a semicolon: `function f(; a=1, b=2)...`

  - In function calls, separating positional arguments from keyword arguments.
    
      + This is optional, but may be used for clarity, especially when splatting keyword arguments when there are no positional arguments
  - To construct literal `NamedTuple`s: `(; a=1, b=2)`.
    
      + The semicolon is optional, but if there is only one key/value pair, either a leading semicolon `(; a=1)` or trailing comma `(a=1,)` must be used to distinguish it from the expression `a=1` wrapped in parentheses. (The leading semicolon is preferred for a couple reasons. A single-element `Tuple` also uses a trailing comma; also, it's easy to accidentally remove the required trailing comma when removing all but one elements from the expression.)
      + An empty `NamedTuple` can also be constructed with `(;)`.
      + You can also construct `NamedTuple`s programmatically by splatting an iterator yielding key-value pairs after the semicolon: `(; a=1, my_namedtuple..., b=2)`.
  - On the left-hand side of an assignment, to unpack/"destructure" a `NamedTuple` or `struct` (starting in Julia 1.7).
    
      + `(; a, b) = x` is equivalent to the assignments `a = x.a` and `b = x.b`
  - For completeness, there are a couple unrelated uses of semicolons:
    
      + To separate statements without a line break, as in `a = x.a; b = x.b`
    
      + To separate array literals for vertical concatenation, as in `A_2x3 = [1 2 3; 4 5 6]`
        
          * N semicolons concatenate along the Nth dimension, as in `A_3x2 = [1:3 ;; 4:6]`

In `SchematicDrivenLayout` specifically, we often work with the `parameters` of a `Component` as a `NamedTuple`.

**How do I add a schematic node so that it's at a fixed position on the chip?**

One way to do that is to make a top-level parent component with a hook at the position you want. For example, you can use the built-in [`SchematicDrivenLayout.Spacer`](@ref) component:

```julia
g = SchematicGraph("fixed_demo")
spacernode = add_node!(g, Spacer(p1=Point(6mm, 1mm)))
fuse!(g, spacernode => :p1_north, mycomp => :myhook)
```

Any "root" node (one that's not attached to any previously added node by any chain of connections; this always includes the first node added to a graph) will have its origin at the global origin.

**How do I attach one component to another if there's no hook where I need it?**

If you need some offset relative to existing hooks, you can use the `Spacer` (see above)
with a `p0` compass hook fused to one component and a `p1` compass hook fused to the other.

For truly ad-hoc positioning, you can use `fuse!` with an actual `Hook` object rather than a
`Symbol` identifying the `Hook` for one or both components. For example, this might be appropriate for
labeling and annotation:

```julia
fuse!(
    g,
    mynode => PointHook(0.5mm, 0.5mm, 90°),
    ArrowAnnotation(text="(0.5mm, 0.5mm) in mynode's coordinate system") => :tip
)
```

However, if you find yourself
needing a consistent hook that doesn't already exist for `MyComponent`, then it's generally
better to update the component definition so that the hook is available by name through
`hooks(::MyComponent)`.

**How do I make sure there aren't any bridges along feedline segments with coupled devices?**

You can define a short, straight `Path` and couple each device to one of those, then route the feedline between the endpoints of coupling segments.

**I edited a component's `_geometry!` method but I'm still getting the old geometry. Can I get the new geometry without restarting Julia?**

First, make sure the new code is being loaded. You can use [Revise](https://timholy.github.io/Revise.jl/stable/) to automatically use updated code within any package you load with `import` or `using` as well as any scripts loaded with `includet`.

Most component types, including those defined using `@compdef`, contain a `_geometry` field
that allows them to store their geometry so that it is only generated once.
It is not marked as dirty or automatically regenerated when geometry methods change. Currently, to regenerate the geometry, you have to empty the geometry or instantiate a new component. (For composite components, there are also similar fields for their graph, schematic, and hooks.)
