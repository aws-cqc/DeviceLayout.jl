# [Rendering and File Export](@id concept-rendering)

"Rendering" in DeviceLayout.jl is the conversion of "native" geometry data to the geometric primitives of a particular backend. The results of rendering can then be exported with that backend to a file. For example:

  - Rendering geometry to a `Cell` converts entities to `Polygons`, suitable for export with the GDSII and graphical display backends.
  - Rendering to a `SolidModel` uses the primitives of the Open CASCADE Technology kernel, including 2D surfaces bounded by combinations of straight lines, circular arcs, and cubic B-splines. For more on 3D rendering with `SolidModel`, see [3D Geometry](./solidmodels.md).

Different backends also support different kinds of metadata, so rendering must also map native metadata (`SemanticMeta`) to the target backend's metadata.

See [API Reference: Rendering](@ref api-rendering).

## Rendering Options

The behavior of [`render!`](@ref) can be customized with keyword arguments. Many of these are built in:

- Arbitrary curves discretized by `adapted_grid` use `max_recursions, max_change, rand_factor, grid_step` (see [Rendering Arbitrary Paths](#Rendering-Arbitrary-Paths) below)
- `atol` is the absolute tolerance used for discretizing other curves (default `1.0nm`)
- `Δθ` can be provided to render circles and ellipses with an angular step rather than `atol`
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

This lets a single design produce different outputs for fabrication versus simulation.

## Rendering Arbitrary Paths

A `Segment` and `Style` together define one or more closed curves in the plane.
The job of rendering to a `Cell` is to approximate these curves by closed polygons. In many cases, including circular arcs and simple styles along B-spline segments, [DeviceLayout.discretize_curve](@ref) is used. This discretization uses curvature information to render the curve to a tolerance provided to `render!` using the `atol` keyword (default `1.0nm`). For these curves, assuming slowly varying curvature, no point on the true curve is more than approximately `atol` from the discretization. To enable rendering
of styles along generic paths in the plane, an adaptive algorithm based on a maximum allowed change in direction `max_change` ([DeviceLayout.adapted_grid](@ref)) is used when no other
method is available.

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

  - `width`: Specifies the width parameter. A unitless number will give the width in pixels,
    72dpi. You can also give a length in any unit using a `Unitful.Quantity`, e.g. `u"4inch"` if
    you had previously done `using Unitful`.
  - `height`: Specifies the height parameter. A unitless number will give the width in pixels,
    72dpi. You can also give a length in any unit using a `Unitful.Quantity`. The aspect ratio
    of the output is always preserved so specify either `width` or `height`.
  - `layercolors`: Should be a dictionary with `Int` keys for layers and RGBA tuples as values.
    For example, (1.0, 0.0, 0.0, 0.5) is red with 50% opacity.
  - `bboxes`: Specifies whether to draw bounding boxes around the bounds of cell arrays or
    cell references (true/false).