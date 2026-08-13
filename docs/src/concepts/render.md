# [Rendering and File Export](@id concept-rendering)

"Rendering" in DeviceLayout.jl is the conversion of "native" geometry data to the geometric primitives of a particular backend. The results of rendering can then be exported with that backend to a file. For example:

  - Rendering geometry to a `Cell` converts entities to `Polygons`, suitable for export with the GDSII and graphical display backends.
  - Rendering to a `SolidModel` uses the primitives of the Open CASCADE Technology kernel, including 2D surfaces bounded by combinations of straight lines, circular arcs, and cubic B-splines. For more on 3D rendering with `SolidModel`, see [3D Geometry](./solidmodels.md).

Different backends also support different kinds of metadata, so rendering must also map native metadata (`SemanticMeta`) to the target backend's metadata.

See [API Reference: Rendering](@ref api-rendering).

## Rendering Options

The behavior of [`render!`](@ref) can be customized with keyword arguments. Many of these are built in:

- `atol` is the absolute tolerance used for discretizing curves (default `1.0nm`)
- `Δθ` can be provided to render circles and ellipses with an angular step rather than `atol`
- `rtol` can be provided to render tolerance-controlled curves with tolerance `max(atol, rtol*local_curvature_radius)`
- `map_meta` is a function that takes metadata as input and returns metadata suitable for the backend

Additional rendering options can be provided for user-defined [conditional rendering](#Conditional-Rendering).

## Targets

Rendering options and the `map_meta` function can also be provided using a `Target` instead of keywords: `render!(cell, coordsys, target)`. This is especially useful in schematic-driven design, where various `Target`s can be specified as part of your [PDK](./pdks.md), allowing you to target different process technologies or simulation backends given a single design. (The name "Target" is meant to evoke "compilation target".)

See the [Targets API](@ref api-targets) reference.

[`LayoutTarget`](@ref SchematicDrivenLayout.LayoutTarget) is used for rendering to a `Cell`. It maps `SemanticMeta` to `GDSMeta` (GDS layer/datatype pairs) using
the layer vocabulary defined in a [`ProcessTechnology`](@ref):

```julia
tech = ProcessTechnology(
    (; metal_negative=GDSMeta(0), junction=GDSMeta(5, 1)),  # layer map
    (;)                                                     # process params
)
target = ArtworkTarget(tech)
```

Two convenience constructors configure common defaults:

- [`ArtworkTarget`](@ref) sets the rendering options `simulation=false, artwork=true` and is used for fabrication mask output
- [`SimulationTarget`](@ref) sets `simulation=true, artwork=false` and is used for 2D simulation geometry

Both create a `LayoutTarget` under the hood. The `rendering_options` flags determine
which conditionally-rendered entities appear (see [Conditional Rendering](#conditional-rendering) below).

For rendering to 3D, there is [`SolidModelTarget`](@ref SchematicDrivenLayout.SolidModelTarget), which controls rendering options, metadata mapping, and operations in the 2D-to-3D pipeline. For more detail, see [Concepts: Solid Models](@ref concept-solidmodeltarget).

## Conditional Rendering

Not every entity belongs in every output. DeviceLayout provides tools to tag entities
for selective rendering using [styles](@ref concept-entitystyles):

- **`NoRender`**: A style that suppresses an entity entirely (equivalent to `NORENDER_META`).
- **`OptionalStyle`**: Renders an entity with one style or another based on a keyword flag in the rendering options.
- **`not_simulated(entity)`**: Entity rendered except when rendering options include `simulation=true` (applies `OptionalStyle` that defaults to no-op `Plain` style, toggled to `NoRender` when `simulation=true`).
- **`only_simulated(entity)`**: Entity rendered only when `simulation=true`.
- **`not_solidmodel(entity)` / `only_solidmodel(entity)`**: Similarly toggles rendering to 3D targets.

This lets a single design produce different outputs for fabrication versus simulation. These methods can also be used on `Path`s, as shorthand for applying them to `undecorated(simplify(pa))`, returning a single entity without any attached references.

These also have in-place versions that can be applied to `CoordinateSystem`s (as in `not_simulated!(cs)`), which replace entities with their styled versions. `Path`s and `Cell`s in the reference hierarchy of `cs` are replaced with equivalent `CoordinateSystem`s containing their geometry and references.

## Rendering Arbitrary Paths

A `Segment` and `Style` together define one or more closed curves in the plane.
The job of rendering to a `Cell` is to approximate these curves by closed polygons. In many cases, including circular arcs and simple styles along B-spline segments, [DeviceLayout.discretize_curve](@ref) is used. This discretization uses curvature information to render the curve to a tolerance provided to `render!` using the `atol` keyword (default `1.0nm`). For these curves, assuming slowly varying curvature, no point on the true curve is more than approximately `atol` from the discretization. To enable rendering
of styles along generic paths in the plane, segment/style rendering falls back to this same
curvature-based discretization when no specialized polygon method is available.

In some cases, custom rendering methods are implemented when it would improve performance
for simple structures or when special attention is required. The rendering methods can
specialize on either the `Segment` or `Style` types, or both.

## Saving Layouts

To save or load layouts in any format, make sure you are `using FileIO`.

This package can load/save patterns in the GDSII format for use with lithography
systems. Options are provided to `save` using the `options` keyword with [`GDSWriterOptions`](@ref).

Using the [Cairo graphics library](https://cairographics.org), it is possible to save
cells into SVG, PDF, and EPS vector graphics formats, or into the PNG raster graphic
format. This enables patterns to be displayed in web browsers, publications, presentations,
and so on. You can save a cell to a graphics file by, e.g. `save("/path/to/file.svg", mycell)`. Possible keyword arguments include:

  - `width`: Output width. A unitless number gives pixels. A `Unitful.Quantity`, such as
    `u"4inch"`, is converted to pixels using `dpi`. If `height` is omitted, it is chosen to
    preserve the rendered region's aspect ratio.
  - `height`: Output height, with the same unitless-pixel or physical-length behavior as
    `width`. If `width` is omitted, it is chosen to preserve the aspect ratio. Supplying both
    dimensions uses them exactly.
  - `dpi`: Resolution used to convert physical `width` and `height` values to pixels, and for
    the default four-inch width. It does not rescale unitless pixel dimensions. The default is
    72.
  - `bbox`: A [`Rectangle`](@ref) in layout coordinates to use as the viewport. Geometry outside
    the rectangle is clipped by the graphics surface.
  - `metadata_filter`: A predicate passed to [`flatten`](@ref) to select metadata before
    drawing. For example, `layer_inclusion([GDSMeta(1, 0)], [])` renders only that GDS layer
    and datatype.
  - `layercolors`: A dictionary mapping either exact `GDSMeta` values or integer GDS layer
    numbers to RGBA tuples. Exact metadata keys allow datatypes on one layer to have different
    colors. For example, `(1.0, 0.0, 0.0, 0.5)` is red with 50% opacity.
  - `background`: `:transparent` (the default), `:white`, `:black`, `nothing`, or an RGB(A)
    tuple with components between zero and one.
  - `bboxes`: Whether to draw yellow bounding boxes around top-level cell arrays or cell
    references (`true`/`false`).

For example, this produces a high-resolution white-background crop containing only one layer:

```julia
save(
    "junction_crop.png",
    cell;
    width=1200,
    bbox=Rectangle(Point(400μm, 200μm), Point(500μm, 300μm)),
    metadata_filter=layer_inclusion(GDSMeta(5, 0), []),
    background=:white
)
```
