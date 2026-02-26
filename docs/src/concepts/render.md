# [Rendering and File Export](@id concept-rendering)

"Rendering" in DeviceLayout.jl is the conversion of "native" geometry data to the geometric primitives of a particular backend. The results of rendering can then be exported with that backend to a file. For example, rendering geometry to a `Cell` converts entities to `Polygons`, suitable for export with the GDSII and graphical display backends. Rendering to a `SolidModel` uses the primitives of the Open CASCADE Technology kernel, including 2D surfaces bounded by combinations of straight lines, circular arcs, and cubic B-splines. For more on 3D rendering with `SolidModel`, see [3D Geometry]()

Different backends also support different kinds of metadata, so rendering must also map native metadata (`SemanticMeta`) to the target backend's metadata.

See [API Reference: Rendering](@ref api-render).

## Rendering Options and Targets

The behavior of [`render!`](@ref) can be customized with keyword arguments. Many of these are built in:

- Arbitary curves discretized by `adapted_grid!` (see below) use `max_recursions, max_change, rand_factor, grid_step`
- `atol` is the absolute tolerance used for discretizing other curves (default `1.0nm`)
- `Δθ` can be provided to render circles and ellipses with an angular step rather than `atol`
- `map_meta` is a function that takes metadata as input and returns metadata suitable for the backend

Users can also use [`OptionalStyle`](@ref) in their geometry, which applies one style or another (e.g. `Plain` vs `NoRender`) based on custom Boolean flags provided as rendering options. There are some built-in utilities for these:

- `not_simulated(ent)` will be rendered unless `render!` is called with `simulation=true`
- `only_simulated(ent)` will only be rendered if `simulation=true`
- `not_solidmodel` and `only_solidmodel` are the same but for the `solidmodel` keyword

Rendering options and the `map_meta` function can also be provided using a `Target` instead of keywords: `render!(cell, coordsys, target)`. (The name "Target" is meant to evoke "compilation target".) See the [Targets API](@ref api-targets) reference.

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