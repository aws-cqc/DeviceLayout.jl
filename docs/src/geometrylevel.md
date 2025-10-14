# Geometry-Level Layout: Overview

DeviceLayout.jl lets you define shapes, place shapes in structures, and place references to structures inside other structures. We call this workflow "geometry-level layout", the most basic way of interacting with DeviceLayout.jl.

Within the DeviceLayout.jl type hierarchy, ["shapes" are `GeometryEntity` subtypes](./geometry.md#Entities) like `Polygon` and `Rectangle`.

["Structures" are `GeometryStructure` subtypes](./geometry.md#Structures) like `Cell`, `CoordinateSystem`, `Path`, and `Component`. A structure can contain many entities (its "elements"), and it associates each entity with its own piece of metadata (generally specifying the "layer" that entity belongs to).

Structures may also contain [references to other structures](./geometry.md#References). The most common `GeometryReference` subtype, `StructureReference`, wraps a structure together with a coordinate transformation that specifies its relative positioning and orientation within the containing structure.

To be more concrete, let's take a look at some examples that showcase different geometry-level workflows.

## Entities: Transformations, Clipping, Styles

Starting with a rectangle, let's demonstrate [transformations](./transformations.md), [polygon clipping](./polygons.md#Clipping), and a [style](./entitystyles.md).

```@example 1
using DeviceLayout, DeviceLayout.PreferredUnits
using FileIO # You will have to add FileIO to the environment if you haven't already

r = centered(Rectangle(20μm, 40μm))
# Create a second rectangle rotated by 90 degrees, positioned below the first
r2 = Align.below(Rotation(90°)(r), r, centered=true) # centered in x-coordinate
r3 = Align.above(r2, r) # Another copy of r2 above the first rectangle
dogbone = union2d([r, r2, r3]) # Boolean union of the three rectangles as a single entity
rounded_dogbone = Rounded(4μm)(dogbone) # Apply the Rounded style
```

The printed output above is a bit hard to read, and it's not necessary to understand it in detail to get started. The most important information here is that `rounded_dogbone` is a certain kind of `GeometryEntity` that only describes the vertices of the dogbone polygon and the rounding radius—in particular, we have not discretized the rounded corners to represent the result as a polygon. In more detail, `rounded_dogbone` is a `StyledEntity{T,U,S}` with three type parameters: the coordinate type `T = typeof(1.0μm}`, the underlying entity type `U = ClippedPolygon{T}`, and the style `S = Rounded{T}`—that is, it is a `GeometryEntity` that composes the result of a polygon clipping (Boolean) operation with a `GeometryEntityStyle` specifying rules for rounding that entity.

## Cells and Rendering

The simplest workflow for generating 2D layouts is to render entities directly to a `Cell`. (That's why we used it for [the "quick start" example](./index.md#Quick-start).)

The [`Cell`](@ref) abstraction is meant to correspond to the GDSII backend, which uses `Polygon` as its only primitive entity type. In other words, rendering a complicated entity like our `rounded_dogbone` to a `Cell` will convert it to a `Polygon` representation of the same shape—just a list of points.

!!! info
    
    By default, `render!(::Cell, ...)` discretizes a `Rounded` curve with absolute tolerance of `1nm`—that's the furthest any point on the true curve is from any line segment on the discretized version. This can be controlled in different ways, like providing the `atol` keyword to `render!`, or by composing the `ToTolerance` style on top of the `Rounded` style. Internally, an `atol` keyword then gets passed to the method `to_polygons(::AbstractPolygon{S}, ::Rounded{T}; kwargs...)`.

```@example 1
cr = Cell("dogbone", nm)
render!(cr, rounded_dogbone, GDSMeta(1))
elements(cr)
```

Our `Rounded` `ClippedPolygon` has been reduced to a mere `Polygon`, as necessary to represent it within the GDSII format. It's also what we need in order to use the SVG backend:

```@example 1
save("dogbone.svg", cr; layercolors=Dict(0 => (0, 0, 0, 1), 1 => (1, 0, 0, 1)));
nothing; # hide
```

```@raw html
<img src="../dogbone.svg" style="width: 1in;"/>
```

!!! info
    
    Our `ClippedPolygon` isn't doing anything special, here—it might as well be a `Polygon` in this example. [The `ClippedPolygon` type](@ref Polygons.ClippedPolygon) mainly exists to represent polygons with holes without having to generate "keyhole" polygons as required by the GDSII format. This ends up being convenient for other backends that don't want keyhole polygons as well as for applying different styles to different boundary or hole contours.

## Paths and References

We can now create references to our cell, place those references in a structure, and render the whole structure to another cell. Let's do that with a [`Path`](@ref) structure, as in our quick-start example:

```@example 1
cref = sref(cr, Point(0.0μm, 0.0μm)) # sref is short for "structure [or single] reference"
p = Path(μm, metadata=GDSMeta())
sty = launch!(p)
straight!(p, 500μm, sty)
turn!(p, π / 2, 150μm)
straight!(p, 500μm)
launch!(p)
turnidx = Int((length(p) + 1) / 2) - 1 # the first straight segment of the path
simplify!(p, turnidx .+ (0:2))
attach!(p, cref, (60μm):(60μm):((pathlength(p[turnidx])) - 60μm), i=turnidx)
c = Cell("decoratedpath", nm)
render!(c, p)
refs(c)
```

The entities making up the `Path` are rendered into `Polygon`s, but the `GeometryReference`s stored in the `Path` are simply placed into our `Cell` as references, since they're already `Cell` references. Note that we have many references to the same `Cell` called `"dogbone"` here—it hasn't been copied.

!!! info
    
    If you're paying close attention, you might have noticed that `Path` handles entity metadata slightly differently than a `GeometryStructure` like `Cell`. The `Path`'s elements—the launchers and CPW-styled segments—are all associated with a single piece of metadata, rather than allowing the possibility of different metadata for each. As a structure, though, the `Path` can still have references to other structures with all sorts of different metadata associated with their elements.

Let's see how it looks:

```@example 1
save("dogbone_path.svg", c; layercolors=Dict(0 => (0, 0, 0, 1), 1 => (1, 0, 0, 1)));
nothing; # hide
```

```@raw html
<img src="../dogbone_path.svg" style="width: 3in;"/>
```

For further examples, we'll hide the line that saves to SVG just to display a cell.

We can also add `Cell` references directly to a `Cell`, for example to apply a global rotation:

```@example 1
c_wrapper = Cell("wrapper", nm)
addref!(c_wrapper, sref(c, rot=90°))
save( # hide
    "rotated_dogbone_path.svg", # hide
    flatten(c_wrapper); # hide
    layercolors=Dict(0 => (0, 0, 0, 1), 1 => (1, 0, 0, 1)) # hide
); # hide
nothing; # hide
```

```@raw html
<img src="../rotated_dogbone_path.svg" style="width: 3in;"/>
```

## Coordinate Systems

We've been working with `Cell`s in the above examples because they're convenient for displaying immediately, but in practice, you'll usually want to work with [`CoordinateSystem`](@ref). The two are very similar—both are subtypes of `AbstractCoordinateSystem`—but where `Cell` is tied to the GDSII backend, `CoordinateSystem` is the "DeviceLayout.jl-native" geometry structure.

In particular, any `GeometryEntity` can be placed in a `CoordinateSystem`, like our `rounded_dogbone` from before. (If `Polygon` is the only `Cell` primitive, then every `GeometryEntity` is a `CoordinateSystem` primitive.) That way, backend-specific decisions about how to render it can be deferred. This will become clear when we get to the `SolidModel` backend below.

```@example 1
csr = CoordinateSystem("dogbone", nm)
place!(csr, rounded_dogbone, SemanticMeta(:bridge))
elements(csr)[1]
```

!!! info
    
    `place!` can only be used with `CoordinateSystem`s. It does the same thing as `render!`, which still works, but the verb is less ambiguous. If you know you're only working with `CoordinateSystem`s, it may be clearer to use `place!`, since `render!` suggests rendering to primitives—which can mean different things depending on the "backend".

We're also free to use any type of metadata to describe layers, not just `GDSMeta`. In this case, we use [`SemanticMeta`](@ref) with the layer symbol `:bridge`.

You can do just about anything with a `CoordinateSystem` that you could do with a `Cell`, and some things you couldn't. For example, rendering a `Path` to a `Cell` converted it into `Polygon`s—a `Cell` can only hold references to other `Cell`s, not arbitrary structures. `CoordinateSystem` doesn't have that limitation:

```@example 1
csref = sref(csr, Point(0.0μm, 0.0μm))
p = Path(nm, metadata=SemanticMeta(:metal_negative))
sty = launch!(p, trace1=4μm, gap1=4μm)
straight!(p, 500μm, sty)
turn!(p, π / 2, 150μm)
straight!(p, 500μm)
launch!(p, trace1=4μm, gap1=4μm)
turnidx = Int((length(p) + 1) / 2) - 1 # the first straight segment of the path
simplify!(p, turnidx .+ (0:2))
attach!(p, csref, (60μm):(60μm):((pathlength(p[turnidx])) - 60μm), i=turnidx)
cs = CoordinateSystem("decoratedpath", nm)
addref!(cs, p) # either render! or place! would do the same thing here
refs(cs)
```

Eventually, we'll still want to turn this into a `Cell`. Since we were using named `SemanticMeta` layers, we just need to specify how to convert them to `GDSMeta`:

```@example 1
layer_record = Dict(:bridge => GDSMeta(1), :metal_negative => GDSMeta())
cell = Cell(cs; map_meta=m -> layer_record[layer(m)])
# Could also say cell = render!(Cell("newcell", nm), cs; map_meta=...)
save( # hide
    "cs_dogbone_path.svg", # hide
    flatten(cell); # hide
    layercolors=Dict(0 => (0, 0, 0, 1), 1 => (1, 0, 0, 1)) # hide
); # hide
nothing; # hide
```

```@raw html
<img src="../cs_dogbone_path.svg" style="width: 3in;"/>
```

## Solid Models

We can also render the same `CoordinateSystem` to a [3D model](./solidmodels.md). DeviceLayout.jl uses [Open CASCADE Technology](https://dev.opencascade.org/), an open-source 3D geometry library, through the API provided by [Gmsh](https://www.gmsh.info/doc/texinfo/gmsh.html), a 3D finite element mesh generator.

Even though our geometry is purely 2D, we can generate a `SolidModel` by providing a map from layer name to position in the third dimension (`zmap`) as well as a list of Booleans, extrusions, and other operations to perform after rendering the 2D entities (`postrender_ops`).

It's not really recommended to do this directly from geometry-level layout. There are tools in the schematic-driven layout interface that handle some of the complexity for you. We'll have an analogous overview later that showcases all of that, but for the sake of demonstration, here's a simple (relatively) manual example. (Making bridges in particular can be a bit involved, so there's a helper method to generate the postrendering operations for a basic "staple" configuration.)

We'll add a few more rectangles to help with 3D operations—one that will intersect with our "bridge" pattern to create a 3D "staple", one to extrude the substrate volume, and one to define a larger volume above and below the substrate.

```julia
place!(csr, centered(Rectangle(30μm, 15μm)), :base)
place!.(cs, offset(bounds(cs), 200μm), :substrate)
place!(cs, bounds(cs), :simulated_area)
zmap = (m) -> layer(m) == :simulated_area ? -1000μm : 0μm
postrender_ops = [
    ("substrate_extrusion", SolidModels.extrude_z!, ("substrate", -500μm))
    ("simulated_area_extrusion", SolidModels.extrude_z!, ("simulated_area", 2000μm))
    ("metal", SolidModels.difference_geom!, ("substrate", "metal_negative"))
    SolidModels.staple_bridge_postrendering(; base="base", bridge="bridge")
]
sm = SolidModel("model", overwrite=true)
SolidModels.gmsh.option.setNumber("General.Verbosity", 0)
render!(sm, cs; zmap=zmap, postrender_ops=postrender_ops);
```

We can look at the current model in the Gmsh GUI:

```julia
SolidModels.gmsh.fltk.run()
```

```@raw html
<img src="../assets/gmsh_example.png"/>
```

Let's zoom in on the CPW bend:

```@raw html
<img src="../assets/gmsh_zoom.png"/>
```

One notable thing about this solid model is that the arcs in the bent CPW are exact circular arcs. When we render to a `Cell`, all shapes get discretized into `Polygon`s. But since we were working with our "native" `CoordinateSystem`, curved shapes like the CPW bend can be rendered as native curves in the solid geometry kernel. This not only keeps model size down but also allows Gmsh to make better meshes.

Moreover, when DeviceLayout.jl renders path segments and certain other entities, it automatically sets mesh sizing information to help Gmsh make better meshes. (You can also annotate entities with the [MeshSized](@ref) style to provide such information manually.)

```julia
SolidModels.gmsh.model.mesh.generate(3)
```

```@raw html
<img src="../assets/mesh_example.png"/>

<img src="../assets/mesh_zoom.png"/>
```

Compare this to what happens if we render to polygons first.

```julia
layer_record = Dict(
    :substrate => GDSMeta(0),
    :simulated_area => GDSMeta(1),
    :metal_negative => GDSMeta(2),
    :base => GDSMeta(3),
    :bridge => GDSMeta(4)
)
cell = Cell(cs; map_meta=m -> layer_record[layer(m)])
### Fix for duplicate consecutive points on certain rounded polygons
### GDS doesn't care but Gmsh/OCCT do care
flatten!(cell)
cell.elements .= Polygon.([unique(points(poly)) for poly in elements(cell)])
###
lyr(name) = layername(layer_record[Symbol(name)])
gds_postrender_ops = [
    ("substrate_extrusion", SolidModels.extrude_z!, (lyr("substrate"), -500μm))
    ("simulated_area_extrusion", SolidModels.extrude_z!, (lyr("simulated_area"), 2000μm))
    ("metal", SolidModels.difference_geom!, (lyr("substrate"), lyr("metal_negative")))
    SolidModels.staple_bridge_postrendering(; base=lyr("base"), bridge=lyr("bridge"))
]
sm = SolidModel("model", overwrite=true)
render!(sm, cell; zmap=zmap, postrender_ops=gds_postrender_ops)
SolidModels.gmsh.model.mesh.generate(2) # 3D meshing may hit an error—have to be careful about postrendering
```

Not only is this `render!` call much slower, but the mesh is forced to use every point on the 1nm-tolerance-discretization of the curve. Without any help from the rich information in the original geometry, Gmsh also uses its default settings—resulting in a very poor mesh.

```@raw html
<img src="../assets/mesh_bad.png"/>
```

## Data flow diagrams

It may be easier to understand the flow of data with a diagram. Here's one for the "quick start" workflow, working directly with `Cell`s:

```@raw html
<img src="../assets/cell_dataflow.jpg"/>
```

And here's a diagram for the typical `CoordinateSystem` workflow:

```@raw html
<img src="../assets/coordinatesystem_dataflow.jpg"/>
```
